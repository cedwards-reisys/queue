package com.test.monolith.test;

import com.fasterxml.jackson.annotation.JsonInclude;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class TestResult {

    private String testName;
    private boolean passed;
    private String details;
    private long durationMs;
    private String error;

    public TestResult() {}

    public TestResult(String testName, boolean passed, String details, long durationMs, String error) {
        this.testName = testName;
        this.passed = passed;
        this.details = details;
        this.durationMs = durationMs;
        this.error = error;
    }

    public static TestResult success(String testName, String details, long durationMs) {
        return new TestResult(testName, true, details, durationMs, null);
    }

    public static TestResult failure(String testName, String details, long durationMs, String error) {
        return new TestResult(testName, false, details, durationMs, error);
    }

    public String getTestName() {
        return testName;
    }

    public void setTestName(String testName) {
        this.testName = testName;
    }

    public boolean isPassed() {
        return passed;
    }

    public void setPassed(boolean passed) {
        this.passed = passed;
    }

    public String getDetails() {
        return details;
    }

    public void setDetails(String details) {
        this.details = details;
    }

    public long getDurationMs() {
        return durationMs;
    }

    public void setDurationMs(long durationMs) {
        this.durationMs = durationMs;
    }

    public String getError() {
        return error;
    }

    public void setError(String error) {
        this.error = error;
    }
}
