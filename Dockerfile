FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git build-essential libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4
COPY . .

EXPOSE 9292
CMD ["bundle", "exec", "puma", "-p", "9292", "config.ru"]
