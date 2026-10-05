FROM perl:5.42 AS build
WORKDIR /app
RUN cpanm --notest App::cpm
COPY cpanfile .
RUN cpm install --without-test

FROM perl:5.42-slim
WORKDIR /app
COPY --from=build /app/local local
COPY bin bin
COPY lib lib
USER nobody
EXPOSE 8080
ENTRYPOINT ["perl", "bin/sipping", "--listen", "0.0.0.0:8080"]
