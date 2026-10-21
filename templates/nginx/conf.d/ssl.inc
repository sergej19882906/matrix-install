    ssl_certificate     /etc/letsencrypt/live/${LETSENCRYPT_CERT}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${LETSENCRYPT_CERT}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;
    ssl_stapling on;
    ssl_stapling_verify on;
