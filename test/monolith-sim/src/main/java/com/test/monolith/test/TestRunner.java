package com.test.monolith.test;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;

@Component
public class TestRunner {

    private static final Logger log = LoggerFactory.getLogger(TestRunner.class);

    private final SmallMessageTest smallMessageTest;
    private final LargeMessageTest largeMessageTest;
    private final TransactionTest transactionTest;
    private final PrefetchTest prefetchTest;
    private final RequestReplyTest requestReplyTest;

    public TestRunner(SmallMessageTest smallMessageTest,
                      LargeMessageTest largeMessageTest,
                      TransactionTest transactionTest,
                      PrefetchTest prefetchTest,
                      RequestReplyTest requestReplyTest) {
        this.smallMessageTest = smallMessageTest;
        this.largeMessageTest = largeMessageTest;
        this.transactionTest = transactionTest;
        this.prefetchTest = prefetchTest;
        this.requestReplyTest = requestReplyTest;
    }

    public List<TestResult> runAll() {
        List<TestResult> results = new ArrayList<>();
        long start = System.currentTimeMillis();

        log.info("========== Starting all compatibility tests ==========");

        // Small message
        log.info("--- Running: small-message ---");
        results.add(smallMessageTest.run());

        // Large messages (all sizes)
        log.info("--- Running: large-message (all sizes) ---");
        results.addAll(largeMessageTest.runAllSizes());

        // Transaction commit
        log.info("--- Running: transaction-commit ---");
        results.add(transactionTest.runCommit());

        // Transaction rollback
        log.info("--- Running: transaction-rollback ---");
        results.add(transactionTest.runRollback());

        // Prefetch (default: 100 messages x 100KB)
        log.info("--- Running: prefetch ---");
        results.add(prefetchTest.run(100, 100));

        // Request-reply
        log.info("--- Running: request-reply ---");
        results.add(requestReplyTest.run());

        long totalDur = System.currentTimeMillis() - start;
        int passed = 0;
        int failed = 0;
        for (TestResult r : results) {
            if (r.isPassed()) {
                passed++;
            } else {
                failed++;
            }
        }

        log.info("========== All tests completed in {}ms: {}/{} passed, {}/{} failed ==========",
                totalDur, passed, results.size(), failed, results.size());

        return results;
    }
}
