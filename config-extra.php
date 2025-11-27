// Exemplo de configurações extras
// Este código será injetado diretamente no config.php

// Forçar SSL se estiver atrás de um proxy (comum no CapRover)
$CFG->sslproxy = 1;

// Configurações de Debug (remover em produção)
// $CFG->debug = 32767;
// $CFG->debugdisplay = 1;

// Configuração de Reverse Proxy
$CFG->reverseproxy = 1;