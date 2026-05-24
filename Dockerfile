FROM python:3.11-slim-bookworm
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless librdkafka-dev gcc python3-dev curl wget procps git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV AIRFLOW_HOME=/opt/airflow
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="/home/airflow/.local/bin:${PATH}"

# Устанавливаем стек 2.7.3 + StatsD плагин для мониторинга Prometheus
RUN pip install --no-cache-dir \
    "apache-airflow==2.7.3" \
    "apache-airflow[statsd]" \
    "psycopg2-binary" \
    "pyspark==3.5.0" \
    "confluent-kafka==2.4.0" \
    "apache-airflow-providers-apache-spark" \
    "apache-airflow-providers-amazon" \
    "apache-airflow-providers-cncf-kubernetes"

# Скачиваем JAR-файлы для Spark (включая hadoop-aws для Workload Identity)
RUN SPARK_JARS_DIR=$(python3 -c 'import pyspark; print(pyspark.__path__)')/jars && \
    wget https://maven.org -P $SPARK_JARS_DIR && \
    wget https://maven.org -P $SPARK_JARS_DIR && \
    wget https://maven.org -P $SPARK_JARS_DIR

# Заметь: строки COPY dags/ ТУТ БОЛЬШЕ НЕТ. Папку наполнит GitSync.
RUN mkdir -p ${AIRFLOW_HOME}/dags ${AIRFLOW_HOME}/logs && \
    chown -R 1000:0 ${AIRFLOW_HOME} && chmod -R 777 ${AIRFLOW_HOME}

WORKDIR ${AIRFLOW_HOME}
USER 1000
