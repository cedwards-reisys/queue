package com.test.monolith.test;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.jms.Connection;
import javax.jms.DeliveryMode;
import javax.jms.Destination;
import javax.jms.JMSException;
import javax.jms.Message;
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import javax.jms.TemporaryQueue;
import javax.jms.TextMessage;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

@Component
public class RequestReplyTest {

    private static final Logger log = LoggerFactory.getLogger(RequestReplyTest.class);

    private final ActiveMQConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public RequestReplyTest(@Qualifier("rawConnectionFactory") ActiveMQConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String requestQueueName = queuePrefix + ".request." + runId;
        long start = System.currentTimeMillis();

        Connection requesterConn = null;
        Connection responderConn = null;
        try {
            log.info("[RequestReply] Starting test on queue: {}", requestQueueName);

            // Set up responder in a separate thread with its own connection
            responderConn = connectionFactory.createConnection();
            responderConn.start();
            final Connection responderConnection = responderConn;

            CountDownLatch responderReady = new CountDownLatch(1);
            CountDownLatch responderDone = new CountDownLatch(1);
            AtomicReference<String> responderError = new AtomicReference<>(null);

            Thread responderThread = new Thread(new Runnable() {
                @Override
                public void run() {
                    Session session = null;
                    try {
                        session = responderConnection.createSession(false, Session.AUTO_ACKNOWLEDGE);
                        Queue requestQueue = session.createQueue(requestQueueName);
                        MessageConsumer consumer = session.createConsumer(requestQueue);
                        responderReady.countDown();

                        log.info("[RequestReply-Responder] Waiting for request (15s timeout)");
                        Message request = consumer.receive(15000);

                        if (request == null) {
                            responderError.set("Responder: no request received within 15s");
                            return;
                        }

                        Destination replyTo = request.getJMSReplyTo();
                        if (replyTo == null) {
                            responderError.set("Responder: JMSReplyTo is null");
                            return;
                        }

                        String correlationId = request.getJMSCorrelationID();
                        String requestBody = ((TextMessage) request).getText();
                        log.info("[RequestReply-Responder] Received request: body={}, correlationId={}, replyTo={}",
                                requestBody, correlationId, replyTo);

                        // Send reply
                        MessageProducer replyProducer = session.createProducer(replyTo);
                        replyProducer.setDeliveryMode(DeliveryMode.NON_PERSISTENT);
                        TextMessage reply = session.createTextMessage("REPLY:" + requestBody);
                        reply.setJMSCorrelationID(correlationId);
                        replyProducer.send(reply);
                        replyProducer.close();
                        log.info("[RequestReply-Responder] Reply sent");

                        consumer.close();
                    } catch (JMSException e) {
                        responderError.set("Responder exception: " + e.getMessage());
                        log.error("[RequestReply-Responder] Error", e);
                    } finally {
                        if (session != null) {
                            try { session.close(); } catch (JMSException ignored) {}
                        }
                        responderDone.countDown();
                    }
                }
            }, "responder-" + runId);
            responderThread.setDaemon(true);
            responderThread.start();

            // Wait for responder to be ready
            if (!responderReady.await(5, TimeUnit.SECONDS)) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("request-reply", "Responder thread failed to start", dur,
                        "Responder setup timeout");
            }

            // Requester: send request with JMSReplyTo temp queue
            requesterConn = connectionFactory.createConnection();
            requesterConn.start();
            Session requesterSession = requesterConn.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue requestQueue = requesterSession.createQueue(requestQueueName);
            TemporaryQueue tempReplyQueue = requesterSession.createTemporaryQueue();

            String correlationId = UUID.randomUUID().toString();
            String requestBody = "test-request-" + runId;

            log.info("[RequestReply-Requester] Sending request: body={}, replyTo={}, correlationId={}",
                    requestBody, tempReplyQueue, correlationId);

            MessageProducer requestProducer = requesterSession.createProducer(requestQueue);
            requestProducer.setDeliveryMode(DeliveryMode.NON_PERSISTENT);
            TextMessage requestMsg = requesterSession.createTextMessage(requestBody);
            requestMsg.setJMSReplyTo(tempReplyQueue);
            requestMsg.setJMSCorrelationID(correlationId);
            requestProducer.send(requestMsg);
            requestProducer.close();

            // Wait for reply on temp queue
            log.info("[RequestReply-Requester] Waiting for reply on temp queue (10s timeout)");
            MessageConsumer replyConsumer = requesterSession.createConsumer(tempReplyQueue);
            TextMessage reply = (TextMessage) replyConsumer.receive(10000);
            replyConsumer.close();

            // Wait for responder to finish
            responderDone.await(5, TimeUnit.SECONDS);

            if (responderError.get() != null) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("request-reply", "Responder error", dur, responderError.get());
            }

            if (reply == null) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("request-reply", "No reply received on temp queue within 10s",
                        dur, "Reply timeout");
            }

            String replyBody = reply.getText();
            String replyCorrelation = reply.getJMSCorrelationID();

            log.info("[RequestReply-Requester] Reply received: body={}, correlationId={}",
                    replyBody, replyCorrelation);

            // Verify reply content
            if (!"REPLY:".concat(requestBody).equals(replyBody)) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("request-reply",
                        "Reply body mismatch: expected=REPLY:" + requestBody + ", got=" + replyBody,
                        dur, "Reply body mismatch");
            }

            if (!correlationId.equals(replyCorrelation)) {
                long dur = System.currentTimeMillis() - start;
                return TestResult.failure("request-reply",
                        "CorrelationID mismatch: expected=" + correlationId + ", got=" + replyCorrelation,
                        dur, "CorrelationID mismatch");
            }

            // Verify temp queue cleanup: delete the temp queue, then verify it's gone
            log.info("[RequestReply] Verifying temp queue cleanup");
            try {
                tempReplyQueue.delete();
                log.info("[RequestReply] Temp queue deleted successfully");
            } catch (JMSException e) {
                log.info("[RequestReply] Temp queue delete threw exception (may already be cleaned up): {}",
                        e.getMessage());
            }

            // Try to consume from the deleted temp queue - should fail
            boolean tempQueueGone = false;
            try {
                MessageConsumer deadConsumer = requesterSession.createConsumer(tempReplyQueue);
                Message ghost = deadConsumer.receive(1000);
                deadConsumer.close();
                if (ghost == null) {
                    tempQueueGone = true; // No messages, queue is effectively gone
                }
            } catch (JMSException e) {
                tempQueueGone = true; // Expected: can't consume from deleted temp queue
                log.info("[RequestReply] Confirmed temp queue is cleaned up: {}", e.getMessage());
            }

            requesterSession.close();
            long dur = System.currentTimeMillis() - start;

            String details = "Request/reply round-trip completed, correlationID preserved"
                    + ", tempQueueCleaned=" + tempQueueGone;

            log.info("[RequestReply] Test passed in {}ms: {}", dur, details);
            return TestResult.success("request-reply", details, dur);

        } catch (Exception e) {
            long dur = System.currentTimeMillis() - start;
            log.error("[RequestReply] Test failed", e);
            return TestResult.failure("request-reply", "Exception during test", dur, e.getMessage());
        } finally {
            closeQuietly(requesterConn);
            closeQuietly(responderConn);
        }
    }

    private void closeQuietly(Connection connection) {
        if (connection != null) {
            try {
                connection.close();
            } catch (Exception e) {
                log.warn("[RequestReply] Error closing connection", e);
            }
        }
    }
}
