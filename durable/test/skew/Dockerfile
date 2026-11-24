FROM elixir:1.20-otp-29

RUN apt-get update \
 && apt-get install -y --no-install-recommends libfaketime \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s "$(ls /usr/lib/*/faketime/libfaketimeMT.so.1)" /usr/local/lib/libfaketimeMT.so.1

RUN mix local.hex --force && mix local.rebar --force
