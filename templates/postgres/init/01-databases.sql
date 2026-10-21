-- Создание отдельных ролей и баз для каждого компонента Matrix-стека.
CREATE ROLE synapse   LOGIN PASSWORD '${SYNAPSE_DB_PASSWORD}';
CREATE ROLE mas      LOGIN PASSWORD '${MAS_DB_PASSWORD}';
CREATE ROLE keycloak LOGIN PASSWORD '${KEYCLOAK_DB_PASSWORD}';
CREATE ROLE bridgebot LOGIN PASSWORD '${BRIDGE_DB_PASSWORD}';

CREATE DATABASE synapse   OWNER synapse;
CREATE DATABASE mas      OWNER mas;
CREATE DATABASE keycloak OWNER keycloak;
CREATE DATABASE bridgebot OWNER bridgebot;

REVOKE ALL ON DATABASE postgres FROM PUBLIC;
