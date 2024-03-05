# Logs regex

## Nginx
### Access Logs

The log sample:

```
207.90.244.12 - - [07/Sep/2023:08:24:41 +0300] "GET /sitemap.xml HTTP/1.1" 404 162 "-" "-"
```

The Regex matches:

```
(\S*)\s*-\s*(\S*)\s*\[(\d+/\S+/\d+:\d+:\d+:\d+)\s+\S+\]\s*"(\S+)\s+(\S+)\s+\S+"\s*(\S*)\s*(\S*)\s*"([^"]*)"\s*"([^"]*)".*
```
<!--
```
(?P<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?(?P<ip2>, \d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?-? - ?\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})\]\s+\"(?P<method>\S{3,10}) (?P<path>\S+) HTTP\/1\.\d" (?P<response_status>\d{3}) (?P<bytes>\d+) "(?P<referer>(\-)|(.+))?" "(?P<useragent>.+)

(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})
\s(?<remote_user>.*)
\s\[(?<date>\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} +\d{4})\]
\s"(?<request>.*)"
\s(?<status>\d{3})
\s(?<body_bytes_sent>\d+)

```


 
```
(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) (- ){2}\[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})\]


(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+


(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10}) (?P<path>\S+) (?P<protocol_version>HTTP\/1\.\d)" (?P<response_status>\d{3}) (?P<bytes>\d+) "(?P<referer>(\-)|([^\s]*))?" "(?P<useragent>.+)"


(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10}) (?P<path>\S+) (?P<protocol_version>HTTP\/1\.\d)" (?P<response_status>\d{3}) (?P<bytes>\d+) "(?P<referer>(\-)|([^\s]*))?" "(?P<useragent>.+)" ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?


(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10}) (?P<path>\S+) (?P<protocol_version>HTTP\/1\.\d)" (?P<response_status>\d{3}) (?P<bytes>\d+) ?("(?P<referer>(\-)|([^\s]*))?")? ?("(?P<useragent>.+)")? ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?


(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10}) (?P<path>\S+) (?P<protocol_version>HTTP\/1\.\d)" (?P<response_status>\d{3}) (?P<bytes>\d+) ?("(?P<referer>(\-)|([\S]*))?")? ?("(?P<useragent>.+)")? ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?

(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}\S* \[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10}) (?P<path>\S+) (?P<protocol_version>HTTP\/1\.\d)" (?P<response_status>\d{3}) (?P<bytes>\d+) ?("(?P<referer>(\-)|([\S][^"]*))?")? ?("(?P<useragent>.+)")? ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?


(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})? (- ){1,2}(\S* )?\[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} (\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2} \d{2}:\d{2}:\d{2}( (\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10}) (?P<path>\S+) (?P<protocol_version>HTTP\/1\.\d)" (?P<response_status>\d{3}) (?P<bytes>\d+) ?("(?P<referer>(\-)|([\S][^"]*))?")? ?("(?P<useragent>.+)")? ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?

(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?\s(- ){1,2}(\S*\s)?\[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2}\s(\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2}\s\d{2}:\d{2}:\d{2}(\s(\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10})\s(?P<path>\S+)\s(?P<protocol_version>HTTP\/1\.\d)"\s(?P<response_status>\d{3})\s(?P<bytes>\d+)\s?("(?P<referer>(\-)|([\S][^"]*))?")? ?("(?P<useragent>.+)")? ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?
```
-->
```
(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?\s(- ){1,2}(\S*\s)?\[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2}\s(\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2}\s\d{2}:\d{2}:\d{2}(\s(\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10})\s(?P<path>\S+)\s(?P<protocol_version>HTTP\/1\.\d)"\s(?P<response_status>\d{3})\s(?P<bytes>\d+)\s?("(?P<referer>(\-)|([\S][^"]*))?")? ?("(?P<useragent>.+)")? ?(?P<time_taken>\d*\.?\d+)? ?(?P<upstream_response_time>\d*\.?\d+)?
```


<!-- 
### Error Logs

The Log sample:
```
2023/09/06 17:57:16 [error] 27514#27514: *548792 access forbidden by rule, client: 94.156.6.85, server: www.emiratesnbdrewards.sa, request: "OPTIONS / HTTP/1.0"
```
-->

----
### Error logs

The Log sample:
```
2023/09/06 17:57:16 [error] 27514#27514: *548792 access forbidden by rule, client: 94.156.6.85, server: www.em.com, request: "OPTIONS / HTTP/1.0"
```

The Regex matches:
<!-- 
```
(?<date>\d{4}\/\d{2}\/\d{2})? (?<time>\d{2}:\d{2}:\d{2})\[(?<severity>error)\]\d+#\d+\*[0-9]+(?<error_message>.*)client: (?<remote_ip_address>.*)server: (?<server_name>.*)request: (?<request_method>.*) (?<requested_uri>.*)

(?<date>\d{4}\/\d{2}\/\d{2})? (?<time>\d{2}:\d{2}:\d{2})? \[(?<severity>[a-z]+)\] \d+#\d+\: \*[0-9]+(?<error_message>.*)client: (?<remote_ip_address>.*)server: (?<server_name>.*)request: (?<request_method>.*) (?<requested_uri>.*)
(?<date>\d{4}\/\d{2}\/\d{2})? (?<time>\d{2}:\d{2}:\d{2})? \[(?<severity>[a-z]+)\] \d+#\d+\: \*[0-9]+(?<error_message>.*)client: (?<remote_ip_address>.*)server: (?<server_name>.*)request: (?<request_method>.*) (?<requested_uri>.*)
(?<date>\d{4}\/\d{2}\/\d{2})?\s(?<time>\d{2}:\d{2}:\d{2})?\s\[(?<severity>[a-z]+)\]\s\d+#\d+\:\s\*[0-9]+(?<error_message>.*)client:\s(?<remote_ip_address>.*)server:\s(?<server_name>.*)request:\s(?<request_method>.*)\s(?<requested_uri>.*)

(?<date>\d{4}\/\d{2}\/\d{2})?\s(?<time>\d{2}:\d{2}:\d{2})?\s\[(?<severity>[a-z]+)\]\s\d+#\d+\:\s\*[0-9]+(?<error_message>.*)(client:\s(?<remote_ip_address>.*))?(server:\s(?<server_name>.*))?(request:\s(?<request_method>.*)\s(?<requested_uri>.*))?
```
-->
```
(?<date>\d{4}\/\d{2}\/\d{2})?\s(?<time>\d{2}:\d{2}:\d{2})?\s\[(?<severity>[a-z]+)\]\s\d+#\d+\:\s(\*[0-9]+)?(?<error_message>.*)(client:\s(?<remote_ip_address>.*))?(server:\s(?<server_name>.*))?(request:\s(?<request_method>.*)\s(?<requested_uri>.*))?
```

working regex
<!--
```

(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+#\d+:\s(\*\d+\s)?)(?<error_message>.*)(\sclient:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\,\s)?(server:\s(?<server_name>\S*)\,\s)?(request:\s(?<request>\S*)\,\s)?

(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(\*\d+\s)?)(?<error_message>.*?)(\,\s?)(client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(\,\sserver:\s(?<server_name>\S*)\,\s)?(request:\s(?<request>.*))?

(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(\*\d+\s)?)(?<error_message>.*?(\,\s|\n))?(client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(\,\sserver:\s(?<server_name>\S*)\,\s)?(request:\s(?<request>.*))?

(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(\*\d+\s)?)(?<error_message>.*?(\,\s|\n))?(?:client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(?:\,\sserver:\s(?<server_name>\S*)\,\s)?(?:request:\s(?<request>.*))?

(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(\*\d+)?)\s?(?<error_message>.*?(\,\s|$))?(?:client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(\,\s)?(?:server:\s(?<server_name>\S*)\,\s)?(?:request:\s(?<request>.*))?

(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(?:\*\d+)?)\s?(?<error_message>.*?(?:\,\s|$))?(?:client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(?:\,\s)?(?:server:\s(?<server_name>\S*)\,\s)?(?:request:\s(?<request>.*))?


(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(?:\*\d+)?)\s?(?<error_message>.*?(?:\,\s|$))?(?:client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(?:\,\s)?(?:server:\s(?<server_name>\S*)\,\s)?(?:request:\s(?<request>"(?<method>\S{3,10})\s(?P<path>\S+)\s(?P<protocol_version>HTTP\/1\.\d)".*))?


(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(?:\*\d+)?)\s?(?<error_message>.*?(?:\,\s|$))?(?:client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(?:\,\s)?(?:server:\s(?<server_name>\S*)\,\s)?(?:request:\s(?<request>.*))?
```
-->

```
(?<timestamp>\d{4}\/\d{2}\/\d{2}\s\d{2}:\d{2}:\d{2})\s\[(?<severity>\w+)\]\s(\d+\#\d+:\s(?:\*\d+)?)\s?(?<error_message>.*?(?:\,\s|$))?(?:client:\s(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}))?(?:\,\s)?(?:server:\s(?<server_name>\S*)\,\s)?(?:request:\s(?<request>"(?<method>\w{3,10})\s(?<path>\S+)\s(?<protocol_version>HTTP\/\d.\d)"))?
```

----
----
## Tomcat

### Access logs
The Log sample

```
127.0.0.1 - - [07/Sep/2023:06:37:09 +0300] "GET /en/pages/images/web-portal/1.jpg HTTP/1.0" 200 5896
127.0.0.1 - - [07/Sep/2023:07:56:34 +0300] "GET /owa/auth/logon.aspx HTTP/1.0" 404 767
127.0.0.1 - - [07/Sep/2023:08:17:13 +0300] "GET / HTTP/1.0" 302 -
127.0.0.1 - - [07/Sep/2023:08:18:22 +0300] "GET / HTTP/1.0" 302 -
127.0.0.1 - - [07/Sep/2023:08:20:13 +0300] "GET /.env HTTP/1.0" 404 752
127.0.0.1 - - [07/Sep/2023:08:48:43 +0300] "GET / HTTP/1.0" 302 -
127.0.0.1 - - [07/Sep/2023:09:46:16 +0300] "GET / HTTP/1.0" 302 -
127.0.0.1 - - [07/Sep/2023:09:46:17 +0300] "GET /en/customer.html?action=login2 HTTP/1.0" 200 15964
127.0.0.1 - - [07/Sep/2023:09:46:18 +0300] "GET /favicon.ico HTTP/1.0" 200 21630
127.0.0.1 - - [07/Sep/2023:09:46:18 +0300] "GET /en/pages/images/web-portal/favicon.ico HTTP/1.0" 200 4201
```

The Regex matches
```
(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?\s(- ){1,2}(\S*\s)?\[(?P<timestamp>\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2}\s(\+|\-)\d{4})?(?P<timestamp2>\d{4}\-\d{2}\-\d{2}\s\d{2}:\d{2}:\d{2}(\s(\+|\-)\d{4})?)?\]\s+"(?<method>\S{3,10})\s(?P<path>\S+)\s(?P<protocol_version>HTTP\/1\.\d)"\s(?P<response_status>\d{3})?\s(?P<bytes>(\-)|(\d+))?
```

Regex working
```
(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(\s\-\s\-\s)(?<datetime>\[\d{1,2}\/\w+\/\d{4}\:\d{2}:\d{2}:\d{2}\s\+\d{4}\])\s\"(?<method>\w+)\s(?<path>\S+)\s(?<protocol>\w+\/\d.\d)\"\s(?<response>\d{3})\s(?<bytes>\-|\d+)
(?<remote_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(\s\-\s\-\s)\[(?<timestamp>\d{1,2}\/\w+\/\d{4}\:\d{2}:\d{2}:\d{2}\s\+\d{4})\]\s\"(?<method>\w+)\s(?<path>\S+)\s(?<protocol>\w+\/\d.\d)\"\s(?<response>\d{3})\s(?<bytes>\-|\d+)
```

----

```
(?<month>\w{3})\s{1,2}(?<day>\d{1,2})\s(?<time>\d{2}:\d{2}:\d{2})\s(?<hostname>\w+)\s(?<type>\w+):\s\[\s{3,4}(?<cost>\d+.\d+)\]\s(?<message>.+)
```
Apr  8 10:26:42 iZrj96q5fsqt5xzb7a7rlvZ kernel: [   47.928502] IPv6: ADDRCONF(NETDEV_CHANGE): docker0: link becomes ready


<!-- 
## Samples
2023/09/06 17:57:16 [error] 27514#27514: *548792 access forbidden by rule, client: 94.156.6.85, server: www.emiratesnbdrewards.sa, request: "OPTIONS / HTTP/1.0"

2023/09/07 19:01:23 [error] 8007#0: *1 connect() to 127.0.0.1:80 failed (111: Connection refused), client: 127.0.0.1, server: localhost, request: "GET / HTTP/1.1"

2023/09/07 19:01:24 [error] 8007#0: *1 open() "/usr/share/nginx/html/index.html" failed (2: No such file or directory), client: 127.0.0.1, server: localhost, request: "GET / HTTP/1.1"


2023/09/07 19:01:25 [error] 8007#0: *1 404 Not Found: /does-not-exist/


2023/09/07 19:01:26 [error] 8007#0: *1 Internal Server Error: invalid upstream response

2023/09/07 19:01:27 [error] 8007#0: *1 Max redirects reached




2023/09/07 19:01:28 [emerg] 8007#0: nginx: error initializing modules

2023/09/07 19:01:29 [alert] 8007#0: nginx: worker process 10007 died

2023/09/07 19:01:30 [crit] 8007#0: nginx: too many open files

2023/09/07 19:01:31 [error] 8007#0: *1 open() "/usr/share/nginx/html/does-not-exist.html" failed (2: No such file or directory), client: 127.0.0.1, server: localhost, request: "GET /does-not-exist.html HTTP/1.1"

2023/09/07 19:01:32 [warning] 8007#0: *1 client: 127.0.0.1, server: localhost, request: "GET / HTTP/1.1", host: "localhost": client sent too many headers

2023/09/07 19:01:33 [notice] 8007#0: *1 100 connections received

2023/09/07 19:01:34 [info] 8007#0: *1 nginx/1.21.7 started




127.0.0.1 - - uusds [07/Sep/2023:09:46:18 +0300] "GET /enbd/pages/images/web-portal/favicon.ico HTTP/1.0" 200 4201

127.0.0.1 - [07/Sep/2023:09:46:18 +0300] "GET /enbd/pages/images/web-portal/favicon.ico HTTP/1.0" 200 4201

207.90.244.12 - - [07/Sep/2023:08:24:41 +0300] "GET /sitemap.xml HTTP/1.1" 404 162 "-" "-"

207.90.244.12 - - [07/Sep/2023:08:24:41 +0300] "GET /sitemap.xml HTTP/1.1" 404 162 "-" "-"



192.168.1.1 - - [2023-09-07 16:36:00 +0300] "GET /index.html HTTP/1.1" 200 612 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.84 Safari/537.36"

192.168.1.1 - [2023-09-07 16:36:00] "GET /index.html HTTP/1.1" 200 612

192.168.1.1 - - [2023-09-07 16:36:00] "GET /index.html HTTP/1.1" 200 612 "http://www.example.com/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.84 Safari/537.36" 0.024 0.008

192.168.1.1 - - [2023-09-07 16:36:00] "GET /index.html HTTP/1.1" 200 612 0.024

local7.info 192.168.1.1 - - [2023-09-07 16:36:00] "GET /index.html HTTP/1.1" 200 612


127.0.0.1 - - [07/Sep/2023:09:46:18 +0300] "GET /enbd/pages/images/web-portal/favicon.ico HTTP/1.0" 200 4201




Apr  8 10:26:42 iZrj96q5fsqt5xzb7a7rlvZ kernel: [   47.928502] IPv6: ADDRCONF(NETDEV_CHANGE): docker0: link becomes ready

-->