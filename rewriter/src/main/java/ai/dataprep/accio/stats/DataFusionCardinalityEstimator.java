package ai.dataprep.accio.stats;

import ai.dataprep.accio.plan.FedConvention;
import ai.dataprep.accio.plan.FedTableScan;
import org.apache.calcite.rel.RelNode;
import org.apache.calcite.rel.core.Join;
import org.apache.calcite.rel.metadata.RelMetadataQuery;
import org.checkerframework.checker.nullness.qual.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Cardinality estimates backed by the small statistics tables exposed by the
 * Accio DataFusion source. Candidate joins are never executed for estimation.
 */
public class DataFusionCardinalityEstimator extends BaseCardinalityEstimator {
    private static final Logger logger = LoggerFactory.getLogger(DataFusionCardinalityEstimator.class);
    private final Map<String, Double> tableRowCounts = new HashMap<>();
    private final Map<String, Double> columnDistinctCounts = new HashMap<>();
    private final Set<String> missingTableStats = new HashSet<>();
    private final Set<String> missingColumnStats = new HashSet<>();

    private static String normalized(String value) {
        return value.toLowerCase(Locale.ROOT);
    }

    private static String literal(String value) {
        return "'" + value.replace("'", "''") + "'";
    }

    private @Nullable Double querySingleValue(FedConvention convention, String sql) {
        DataSource dataSource = convention.dataSource;
        if (dataSource == null) {
            return null;
        }
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            if (!result.next()) {
                return null;
            }
            double value = result.getDouble(1);
            return result.wasNull() ? null : value;
        } catch (SQLException error) {
            logger.warn("Unable to read DataFusion cardinality statistics: {}", error.getMessage());
            return null;
        }
    }

    private synchronized @Nullable Double tableRowCount(FedConvention convention, String table) {
        String key = normalized(table);
        if (tableRowCounts.containsKey(key)) {
            return tableRowCounts.get(key);
        }
        if (missingTableStats.contains(key)) {
            return null;
        }
        Double value = querySingleValue(
                convention,
                "SELECT row_count FROM accio_table_stats WHERE table_name = " + literal(key));
        if (value == null) {
            missingTableStats.add(key);
        } else {
            tableRowCounts.put(key, value);
        }
        return value;
    }

    private synchronized @Nullable Double columnDistinctCount(
            FedConvention convention, String table, String column) {
        String tableKey = normalized(table);
        String columnKey = normalized(column);
        String key = tableKey + "." + columnKey;
        if (columnDistinctCounts.containsKey(key)) {
            return columnDistinctCounts.get(key);
        }
        if (missingColumnStats.contains(key)) {
            return null;
        }
        Double value = querySingleValue(
                convention,
                "SELECT distinct_count FROM accio_column_stats WHERE table_name = "
                        + literal(tableKey) + " AND column_name = " + literal(columnKey));
        if (value == null) {
            missingColumnStats.add(key);
        } else {
            columnDistinctCounts.put(key, value);
        }
        return value;
    }

    @Override
    public @Nullable Double getRowCount(FedTableScan rel, RelMetadataQuery mq) {
        Double value = tableRowCount((FedConvention) rel.getConvention(), rel.fedTable.tableName);
        return value == null ? super.getRowCount(rel, mq) : value;
    }

    @Override
    public @Nullable Double getRowCountDirectly(FedConvention convention, RelNode rel) {
        // Preserve Accio's NDV-based join estimate instead of executing the
        // candidate join merely to count it.
        if (rel instanceof Join) {
            return null;
        }
        if (rel instanceof FedTableScan) {
            return tableRowCount(convention, ((FedTableScan) rel).fedTable.tableName);
        }
        try {
            return rel.estimateRowCount(rel.getCluster().getMetadataQuery());
        } catch (RuntimeException error) {
            logger.debug("Falling back from DataFusion row-count estimate", error);
            return null;
        }
    }

    private static void collectTableScans(RelNode rel, List<FedTableScan> scans) {
        if (rel instanceof FedTableScan) {
            scans.add((FedTableScan) rel);
            return;
        }
        for (RelNode input : rel.getInputs()) {
            collectTableScans(input, scans);
        }
    }

    @Override
    public @Nullable Double getDomainSizeDirectly(
            FedConvention convention, RelNode rel, String column) {
        List<FedTableScan> scans = new ArrayList<>();
        collectTableScans(rel, scans);
        if (scans.size() == 1) {
            String table = scans.get(0).fedTable.tableName;
            Double value = columnDistinctCount(convention, table, column);
            if (value != null) {
                return value;
            }
            // A table's row count is always a safe upper bound for NDV and is
            // much more informative than the generic 100-row fallback.
            value = tableRowCount(convention, table);
            if (value != null) {
                return value;
            }
        }
        return super.getDomainSizeDirectly(convention, rel, column);
    }
}
