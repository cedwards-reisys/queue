package com.test.microservice.test;

import jakarta.jms.Connection;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.Destination;
import jakarta.jms.JMSException;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.Queue;
import jakarta.jms.Session;
import jakarta.jms.TemporaryQueue;
import jakarta.jms.TextMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

@Component
public class RequestReplyTest {

    private static final Logger log = LoggerFactory.getLogger(RequestReplyTest.class);

    private final ConnectionFactory connectionFactory;

    @Value("${test.queue-prefix}")
    private String queuePrefix;

    public RequestReplyTest(ConnectionFactory connectionFactory) {
        this.connectionFactory = connectionFactory;
    }

    public TestResult run() {
        String runId = UUID.randomUUID().toString().substring(0, 8);
        String requestQueueName = queuePrefix + ".request." + runId;
        long start = System.currentTimeMillis();

        log.info("[RequestReply] Starting test on queue: {}", requestQueueName);

        Connection requesterConnection = null;
        Connection responderConnection = null;

        try {
            requesterConnection = connectionFactory.createConnection();
            responderConnection = connectionFactory.createConnection();
            requesterConnection.start();
            responderConnection.start();

            Session requesterSession = requesterConnection.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue requestQueue = requesterSession.createQueue(requestQueueName);

            // Create temp queue for reply
            TemporaryQueue replyQueue = requesterSession.createTemporaryQueue();
            log.info("[RequestReply] Created temp reply queue: {}", replyQueue.getQueueName());

            // Start responder in a separate thread
            final Connection respConn = responderConnection;
            CompletableFuture<Boolean> responderFuture = CompletableFuture.supplyAsync(() -> {
                try {
                    Session respSession = respConn.createSession(false, Session.AUTO_ACKNOWLEDGE);
                    Queue respRequestQueue = respSession.createQueue(requestQueueName);
                    MessageConsumer respConsumer = respSession.createConsumer(respRequestQueue);

                    log.info("[RequestReply-Responder] Waiting for request...");
                    TextMessage request = (TextMessage) respConsumer.receive(10000);

                    if (request == null) {
                        log.error("[RequestReply-Responder] No request received within timeout");
                        return false;
                    }

                    Destination replyTo = request.getJMSReplyTo();
                    if (replyTo == null) {
                        log.error("[RequestReply-Responder] No JMSReplyTo on request");
                        return false;
                    }

                    // Send reply
                    MessageProducer replyProducer = respSession.createProducer(replyTo);
                    TextMessage reply = respSession.createTextMessage("REPLY:" + request.getText());
                    reply.setJMSCorrelationID(request.getJMSMessageID());
                    replyProducer.send(reply);
                    log.info("[RequestReply-Responder] Sent reply to temp queue");

                    replyProducer.close();
                    respConsumer.close();
                    respSession.close();
                    return true;
                } catch (JMSException e) {
                    log.error("[RequestReply-Responder] Error", e);
                    return false;
                }
            });

            // Send request
            MessageProducer requestProducer = requesterSession.createProducer(requestQueue);
            TextMessage requestMsg = requesterSession.createTextMessage("REQUEST-" + runId);
            requestMsg.setJMSReplyTo(replyQueue);
            requestProducer.send(requestMsg);
            String requestMsgId = requestMsg.getJMSMessageID();
            log.info("[RequestReply] Sent request with JMSReplyTo, messageId={}", requestMsgId);

            // Wait for reply on temp queue
            MessageConsumer replyConsumer = requesterSession.createConsumer(replyQueue);
            TextMessage reply = (TextMessage) replyConsumer.receive(10000);

            // Wait for responder to finish
            Boolean responderOk = responderFuture.get(15, TimeUnit.SECONDS);

            if (reply == null) {
                long duration = System.currentTimeMillis() - start;
                return TestResult.failure("RequestReply", "No reply received within 10s timeout",
                        duration, "Reply timeout");
            }

            if (!responderOk) {
                long duration = System.currentTimeMillis() - start;
                return TestResult.failure("RequestReply", "Responder thread failed",
                        duration, "Responder error");
            }

            String expectedReply = "REPLY:REQUEST-" + runId;
            if (!expectedReply.equals(reply.getText())) {
                long duration = System.currentTimeMillis() - start;
                return TestResult.failure("RequestReply",
                        "Reply content mismatch: expected '" + expectedReply + "', got '" + reply.getText() + "'",
                        duration, "Reply content mismatch");
            }

            log.info("[RequestReply] Reply verified: {}", reply.getText());

            // Clean up temp queue
            replyConsumer.close();
            requestProducer.close();

            // Delete the temp queue
            replyQueue.delete();
            log.info("[RequestReply] Temp queue deleted");

            // Verify temp queue is cleaned up by trying to consume from it
            boolean tempQueueGone = false;
            try {
                Session verifySession = requesterConnection.createSession(false, Session.AUTO_ACKNOWLEDGE);
                MessageConsumer verifyConsumer = verifySession.createConsumer(replyQueue);
                verifyConsumer.close();
                verifySession.close();
            } catch (JMSException e) {
                tempQueueGone = true;
                log.info("[RequestReply] Temp queue confirmed deleted (access failed as expected)");
            }

            requesterSession.close();

            long duration = System.currentTimeMillis() - start;

            String details = "Request sent with JMSReplyTo temp queue, reply received and verified" +
                    (tempQueueGone ? ", temp queue cleanup confirmed" : ", temp queue cleanup could not be confirmed");

            return TestResult.success("RequestReply", details, duration);

        } catch (Exception e) {
            long duration = System.currentTimeMillis() - start;
            log.error("[RequestReply] Test failed", e);
            return TestResult.failure("RequestReply", "Exception during test", duration, e.getMessage());
        } finally {
            closeQuietly(requesterConnection);
            closeQuietly(responderConnection);
        }
    }

    private void closeQuietly(Connection connection) {
        if (connection != null) {
            try {
                connection.close();
            } catch (JMSException e) {
                log.warn("[RequestReply] Error closing connection", e);
            }
        }
    }
}
