FROM nginx:1.27.5-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css actions.css app.js /usr/share/nginx/html/
RUN chown -R nginx:nginx /var/cache/nginx /var/run /usr/share/nginx/html
USER nginx
EXPOSE 8080
