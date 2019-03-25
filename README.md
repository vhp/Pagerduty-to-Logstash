# Pagerduty-to-Logstash
## Description
  pagerduty-to-logstash.rb reads from the /log-entries endpoint of the
Pagerduty Rest API. Each entry is added to a queue and that queue is then
processed. Processing includes adding special tags for Logstash and statistics
such as time since incident creation to each entry. After processing we send
each entry via UDP to a remote host. UDP is said in a generic sense but it's
most likely Logstash which you have setup to ingest JSON. By default the program
gathers logs from just the last hour. Though if you use the '--from' argument
you can go back as far as you like. Just ensure you use RFC 3339 format. Use `-h` option to see examples.

## How to run:
  `fetch.rb --pd_key=example_key --remoteAddr=logstash.example.com --remotePort=8080`
