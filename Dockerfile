# target container
FROM solarkennedy/wine-x11-novnc-docker as build

RUN apt update && apt -y install unzip
RUN mkdir -p /root/reactivedrop/reactivedrop

WORKDIR /root/reactivedrop/reactivedrop

# install anti cheat
RUN mkdir -p /tmp/reactive-drop-anticheat/
COPY bin/install-sourcemod /usr/local/bin/
RUN bash /usr/local/bin/install-sourcemod

# winetricks
RUN cd /usr/local/bin \
    && wget -q https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
    && chmod +x winetricks
RUN winetricks --unattended winxp

# compile plugins
COPY addons/ /root/reactivedrop/reactivedrop/addons/
COPY bin/install.sh /usr/local/bin/

# disable cache
RUN /usr/local/bin/install.sh

FROM alpine
COPY --from=build /root/reactivedrop/reactivedrop/addons/sourcemod/plugins/rd_elo.smx /rd_elo.smx

RUN ls -lah /*.smx

# start command
CMD ["tail", "-f", "/dev/null"]
