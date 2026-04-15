package com.test.microservice.test;

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

        log.info("========== Starting all tests ==========");

        log.info("--- Running SmallMessage test ---");
        results.add(smallMessageTest.run());

        log.info("--- Running LargeMessage tests ---");
        results.addAll(largeMessageTest.run(0));

        log.info("--- Running Transaction-Commit test ---");
        results.add(transactionTest.runCommit());

        log.info("--- Running Transaction-Rollback test ---");
        results.add(transactionTest.runRollback());

        log.info("--- Running Prefetch test ---");
        results.add(prefetchTest.run(100, 100));

        log.info("--- Running RequestReply test ---");
        results.add(requestReplyTest.run());

        long totalDuration = System.currentTimeMillis() - start;
        long passed = results.stream().filter(TestResult::isPassed).count();
        long failed = results.size() - passed;

        log.info("========== All tests complete: {}/{} passed, {} failed, total time {}ms ==========",
                passed, results.size(), failed, totalDuration);

        return results;
    }
}
