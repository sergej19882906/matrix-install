
    ### Legacy-режим MAS: эндпоинты совместимости обслуживает MAS, а не Synapse.
    ### Активируется только при ENABLE_MAS=1 (см. lib/stack.sh).
    ### Регулярные выражения в nginx имеют приоритет над префиксным location /.

    location ~ ^/_matrix/client/(.*)/(login|logout|refresh)$ {
        proxy_pass http://mas:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_read_timeout 300s;
    }
