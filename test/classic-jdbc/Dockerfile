FROM apache/activemq-classic:5.18.6

# Add PostgreSQL JDBC driver to the main lib directory (lib/optional is NOT on classpath)
ADD --chmod=644 https://jdbc.postgresql.org/download/postgresql-42.7.5.jar /opt/apache-activemq/lib/postgresql-42.7.5.jar

# Replace default activemq.xml with JDBC-backed config
COPY activemq.xml /opt/apache-activemq/conf/activemq.xml
