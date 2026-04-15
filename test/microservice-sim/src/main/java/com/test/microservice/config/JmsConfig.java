package com.test.microservice.config;

import jakarta.jms.ConnectionFactory;
import org.apache.activemq.artemis.jms.client.ActiveMQConnectionFactory;
import org.messaginghub.pooled.jms.JmsPoolConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jms.core.JmsTemplate;

@Configuration
public class JmsConfig {

    private static final Logger log = LoggerFactory.getLogger(JmsConfig.class);

    @Value("${spring.artemis.broker-url}")
    private String brokerUrl;

    @Value("${spring.artemis.user}")
    private String user;

    @Value("${spring.artemis.password}")
    private String password;

    @Value("${test.consumer-window-size:1048576}")
    private int consumerWindowSize;

    @Bean
    public ActiveMQConnectionFactory artemisConnectionFactory() {
        log.info("Configuring Artemis ConnectionFactory: url={}, user={}, consumerWindowSize={}",
                brokerUrl, user, consumerWindowSize);

        ActiveMQConnectionFactory factory = new ActiveMQConnectionFactory(brokerUrl, user, password);
        factory.setConsumerWindowSize(consumerWindowSize);
        return factory;
    }

    @Bean
    public JmsPoolConnectionFactory pooledConnectionFactory(ActiveMQConnectionFactory artemisConnectionFactory) {
        JmsPoolConnectionFactory pool = new JmsPoolConnectionFactory();
        pool.setConnectionFactory(artemisConnectionFactory);
        pool.setMaxConnections(20);
        pool.setMaxSessionsPerConnection(500);
        pool.setConnectionIdleTimeout(30000);
        log.info("Pooled connection factory configured: maxConnections=20, maxSessions=500, idleTimeout=30000ms");
        return pool;
    }

    @Bean
    public ConnectionFactory connectionFactory(JmsPoolConnectionFactory pooledConnectionFactory) {
        return pooledConnectionFactory;
    }

    @Bean
    public JmsTemplate jmsTemplate(ConnectionFactory connectionFactory) {
        JmsTemplate template = new JmsTemplate(connectionFactory);
        template.setReceiveTimeout(5000);
        return template;
    }

    /**
     * Returns an unpooled factory for tests that need direct session control
     * (transactions, temp queues, etc).
     */
    @Bean
    public ActiveMQConnectionFactory rawConnectionFactory() {
        ActiveMQConnectionFactory factory = new ActiveMQConnectionFactory(brokerUrl, user, password);
        factory.setConsumerWindowSize(consumerWindowSize);
        return factory;
    }
}
