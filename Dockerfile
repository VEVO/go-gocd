FROM alpine:latest
RUN echo 'while true; do printf "HTTP/1.1 200 OK\n\n%s" "<html><head><title>Monitoring</title></head><body>OK</body></html>" | nc -l -p8080; done' > /cmd.sh \
    && chmod +x /cmd.sh
CMD ["sh", "-c", "/cmd.sh"]
