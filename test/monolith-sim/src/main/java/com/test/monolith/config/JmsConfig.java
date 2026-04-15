package com.test.monolith.config;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.apache.activemq.pool.PooledConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jms.annotation.EnableJms;
import org.springframework.jms.core.JmsTemplate;

import javax.jms.ConnectionFactory;

@Configuration
@EnableJms
public class JmsConfig {

    private static final Logger log = LoggerFactory.getLogger(JmsConfig.class);

    @Value("${spring.activemq.broker-url}")
    private String brokerUrl;

    @Value("${spring.activemq.user}")
    private String brokerUser;

    @Value("${spring.activemq.password}")
    private String brokerPassword;

    @Value("${test.prefetch-size:1000}")
    private int prefetchSize;

    @Bean
    public ActiveMQConnectionFactory activeMQConnectionFactory() {
        String urlWithPrefetch = brokerUrl;
        if (!urlWithPrefetch.contains("jms.prefetchPolicy")) {
            String separator = urlWithPrefetch.contains("?") ? "&" : "?";
            // Append prefetch as nested options for failover URLs
            if (urlWithPrefetch.startsWith("failover:")) {
                // For failover URLs, add prefetch as a nested param on the inner URL
                // or as a top-level option
                urlWithPrefetch = urlWithPrefetch + "&jms.prefetchPolicy.all=" + prefetchSize;
            } else {
                urlWithPrefetch = urlWithPrefetch + separator + "jms.prefetchPolicy.all=" + prefetchSize;
            }
        }

        log.info("Configuring ActiveMQ connection: url={}, user={}, prefetchSize={}",
                brokerUrl, brokerUser, prefetchSize);

        ActiveMQConnectionFactory factory = new ActiveMQConnectionFactory();
        factory.setBrokerURL(urlWithPrefetch);
        factory.setUserName(brokerUser);
        factory.setPassword(brokerPassword);
        factory.setTrustAllPackages(true);
        return factory;
    }

    @Bean
    public PooledConnectionFactory pooledConnectionFactory(ActiveMQConnectionFactory activeMQConnectionFactory) {
        PooledConnectionFactory pooled = new PooledConnectionFactory();
        pooled.setConnectionFactory(activeMQConnectionFactory);
        pooled.setMaxConnections(20);
        pooled.setIdleTimeout(30000);
        pooled.setMaximumActiveSessionPerConnection(500);
        log.info("Pooled connection factory configured: maxConnections=20, idleTimeout=30000ms, maxActiveSessions=500");
        return pooled;
    }

    @Bean
    public ConnectionFactory connectionFactory(PooledConnectionFactory pooledConnectionFactory) {
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
        ActiveMQConnectionFactory factory = new ActiveMQConnectionFactory();
        factory.setBrokerURL(brokerUrl);
        factory.setUserName(brokerUser);
        factory.setPassword(brokerPassword);
        factory.setTrustAllPackages(true);
        return factory;
    }
}
