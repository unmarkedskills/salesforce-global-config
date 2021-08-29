# Container image that runs your code
FROM alpine:3.14

ARG SFDX_URL=https://developer.salesforce.com/media/salesforce-cli/sfdx/versions/7.108.0/d2f9bbd/sfdx-v7.108.0-d2f9bbd-linux-x64.tar.xz

RUN mkdir /root/entrypoint

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /root/entrypoint/entrypoint.sh

# code file to execute when the docker container starts up
ENTRYPOINT ["/root/entrypoint/entrypoint.sh"]

# not using --update option in adding curl "https://github.com/gliderlabs/docker-alpine/blob/master/docs/usage.md"
RUN    apk update \
    && apk add --no-cache \
                    bash \
                    curl \
                    tzdata \
                    xz \
                    jq \
                    npm \
                    git \
                    openssh

RUN    mkdir ~/sfdx \
    && mkdir ~/secrets \
    && wget $SFDX_URL \
    && SFDX_INSTALLER=$(echo $SFDX_URL | sed 's/.*\///') \
    && tar xJf $SFDX_INSTALLER -C ~/sfdx --strip-components 1 \
    && PATH=/root/sfdx/bin:$PATH \
    && rm ~/sfdx/bin/node \
    && ln -s /usr/local/bin/node ~/sfdx/bin/node \
    && sfdx --version \
    && rm $SFDX_INSTALLER \
    && mkdir -p /operation/home \
    && mkdir -p /operation/workspace \
    && mkdir -p /operation/file_commands \
    && mkdir -p /operation/workflow