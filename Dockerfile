FROM ruby:2.2

MAINTAINER Antarkt Ops "ops@antarkt.com"

ENV DOCKER_HOST unix:///var/run/docker.sock
ENV LOGSTASH_URL tcp://logstash:9290
ENV RABBITMQ_URL amqp://guest:guest@localhost:5672

COPY Gemfile /app/DockerLogstash/Gemfile
WORKDIR /app/DockerLogstash
RUN bundle install

COPY main.rb /app/DockerLogstash/main.rb

CMD ruby main.rb