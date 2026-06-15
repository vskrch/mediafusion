# Heroku container deploy — wraps the official MediaFusion image.
ARG MEDIAFUSION_VERSION=6.0.0-beta.22
FROM mhdzumair/mediafusion:${MEDIAFUSION_VERSION}

USER root
COPY start.sh /start.sh
RUN chmod +x /start.sh
USER mediafusion

CMD ["/start.sh"]
