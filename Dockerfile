ARG CADDY_VERSION=2.4.6
ARG LIBINJECTION_VERSION=3.10.0
ARG OWASP_CRS_VERSION=3.3.2

# FROM caddy:${CADDY_VERSION}-builder AS builder
FROM golang:1.17.5-bullseye AS builder

ARG CADDY_VERSION
ARG OWASP_CRS_VERSION
ARG LIBINJECTION_VERSION

# prevent packages from prompting interactive input
ENV DEBIAN_FRONTEND=noninteractive

# install build dependencies
RUN apt-get update && \
  apt-get install -y gcc libc-dev libpcre3-dev

# download, build and install libinjection
RUN wget -O libinjection.tar.gz https://github.com/libinjection/libinjection/archive/refs/tags/v${LIBINJECTION_VERSION}.tar.gz && \
  tar xf libinjection.tar.gz && \
  cd libinjection-${LIBINJECTION_VERSION} && \
  for type in html5 sqli xss; do gcc -std=c99 -Wall -Werror -fpic -c src/libinjection_${type}.c -o libinjection_${type}.o; done && \
  gcc -dynamiclib -shared -o libinjection.so libinjection_sqli.o libinjection_xss.o libinjection_html5.o && \
  mkdir -p /usr/local/include /usr/local/lib && \
  cp *.o *.so /usr/local/lib && \
  cp src/*.h /usr/local/include/ && \
  chmod 444 /usr/local/include/libinjection* && \
  ldconfig /usr/local/lib

# download, build and install coraza and caddy
RUN mkdir -p /go/src/github.com/jptosso && \
  cd /go/src/github.com/jptosso && \
  git clone --depth 1 https://github.com/jptosso/coraza-caddy && \
  cd coraza-caddy && \
  git checkout -q 51db837 && \
  go get -d github.com/caddyserver/caddy/v2@v${CADDY_VERSION} && \
  sed -i 's/\/\/ _ "github.com/_ "github.com/g' caddy/main.go && \
  go mod tidy && \
  CGO_LDFLAGS="-L/usr/local/lib -lpcre" CGO_CFLAGS="-I/usr/local/include" CGO_ENABLED=1 go build caddy/main.go && \
  mv main /usr/bin/caddy

# configure the owasp core rule set (crs)
RUN mkdir -p /etc/caddy/coreruleset && \
  wget https://github.com/coreruleset/coreruleset/archive/refs/tags/v${OWASP_CRS_VERSION}.tar.gz && \
  tar xf v${OWASP_CRS_VERSION}.tar.gz && \
  mv coreruleset-${OWASP_CRS_VERSION}/crs-setup.conf.example /etc/caddy/coreruleset/crs-setup.conf && \
  mv coreruleset-${OWASP_CRS_VERSION}/rules/ /etc/caddy/coreruleset/

# put all the lib files in one place so they're easier to copy in later
RUN mkdir -p /caddy-lib && \
  ldd /usr/bin/caddy | grep '=>' | cut -d' ' -f 3 | xargs -I{} cp -p {} /caddy-lib/

# copy the caddy configuration files
COPY caddy/* /etc/caddy/

# create our distroless runtime image
FROM gcr.io/distroless/static:nonroot

ARG CADDY_VERSION

LABEL caddy.version=${CADDY_VERSION}

ENV TZ="UTC"

COPY --from=builder /lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
COPY --from=builder /caddy-lib/ /usr/lib/x86_64-linux-gnu/

COPY --from=builder /usr/bin/caddy  /usr/bin/caddy

COPY --from=builder --chown=nonroot /etc/caddy/ /etc/caddy/

EXPOSE 80/tcp
EXPOSE 443/tcp

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/caddy"]

CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
