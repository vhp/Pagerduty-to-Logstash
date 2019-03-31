#!/usr/bin/env ruby
#
# Author: Vincent Perricone <vhp@fastmail.fm>
# Date: 3/2019
# Title: Pagerduty-to-Logstash
# Description: See README.md
# License: Released under "Simplified BSD License"
#
require 'docopt'
require 'httparty'
require 'json'
require 'socket'

DEFAULT_TIME_UNIT = (1/24.0) # Default One hour
SLEEP_TIME = 0.5 # Half second

doc = <<DOCOPT
Pagerduty-to-Logstash

Usage:
  #{__FILE__}
  #{__FILE__} [--pd_key=<key>] [--from=<time>] [--until=<time>] [--remoteAddr=<addr>] [--remotePort=<port>]
  #{__FILE__} -h | --help

Options:
  -h --help            Show this screen.
  --remoteAddr=<addr>  Remote Address.
  --remotePort=<port>  Remote Port.
  --pd_key=<key>       Pagerduty REST API Key V2.
  --from=<time>        Start Time, defaults to -1 hour. [default: #{(DateTime.now - DEFAULT_TIME_UNIT).rfc3339()}]
  --until=<time>       End Time, defaults to now. [default: #{DateTime.now.rfc3339()}]
DOCOPT

# Interact with Pagerduty Rest API V2.
class Pagerduty
  include HTTParty
  format :json
  base_uri 'https://api.pagerduty.com'

  def initialize(_args)
    @pd_key = _args['--pd_key']
    @query_limit = 25
    @since_time = _args['--from']
    @until_time = _args['--until']
    @remote_addr = _args['--remoteAddr']
    @remote_port = _args["--remotePort"]
    @log_entries_queue = Queue.new
    # Query and headers for connecting to pagerduty can be adjusted here.
    @options = { :query =>
                 {
                   time_zone: 'UTC',
                   limit: @query_limit,
                   since: @since_time,
                   until: @until_time,
                   offset: 0,
                   is_overview: false,
                   include: ['','incidents', 'services', 'channels', 'teams']
                 },
                 :headers => {
                   'Content-Type' => 'application/json',
                   'Accept' => 'application/vnd.pagerduty+json;version=2',
                   'Authorization' => "Token token=#{@pd_key}"
                 }
    }
  end

  # Send data via UDP to remote_addr:remote_port. Must be within the expected size.
  def send(data)
    sock = UDPSocket.new
    if JSON.dump(data).bytesize <= 65507 #Check UDP Limit
      sock.send(JSON.dump(data), 0, @remote_addr, @remote_port.to_i)
    else
      puts "Log-entry skipped as it's too large for datagram/system: \n #{JSON.pretty_generate(data)}\n\n" end
    sock.close
  end

  # Let's empty the queue and send each entry to send().
  def flush_queue()
    until @log_entries_queue.empty?
      self.send(@log_entries_queue.pop())
      sleep(SLEEP_TIME)
    end
  end

  # How much time has passed creation of incident. This is applied to each
  # entry. Not just the resolved entry.
  def calculate_seconds_passed?(entry)
    incident_created_at = entry['incident']['created_at']
    most_recent_update = entry['created_at']
    start_time = Time.parse(incident_created_at)
    recent_time = Time.parse(most_recent_update)
    result = recent_time - start_time
    result >= 0 ? (return result) : (return 0)
  end

  def on_weekend?(st)
    [0, 6, 7].include?(st.wday)
  end

  def during_office_hours?(st)
    st.utc
    workday_start_hour = 14
    workday_end_hour = 22
    if ! on_weekend?(st)
      Range.new(
        Time.utc(st.year, st.month, st.day, workday_start_hour),
        Time.utc(st.year, st.month, st.day, workday_end_hour)
      ).cover?(st)
    else
      return false
    end
  end

  def which_shift(incident_created_at)
    st = Time.parse(incident_created_at).utc
    if during_office_hours?(st)
      return 'working'
    else
      return 'non_working'
    end
  end

  def process_json(json)
    patterns = [
      /^\S+\sService:([^\s]+)?/i,
      /^\[FIRING\:.\]\s([^\s]+)?/i,
      /^Host:\S+\sis\s(DOWN)+\s/i
    ]
    re = Regexp.union(patterns)
    json['tags'] = ['pagerduty']
    json['custom'] = {}
    json['custom']['seconds_since_incident_creation'] = calculate_seconds_passed?(json)
    json['custom']['oncall_shift'] = which_shift(json['incident']['created_at'])
    # Data comes out of scan like so [[nil, "ServiceName"]], index 0 for first pattern and 1 for second pattern
    matched = json['incident']['description'].scan(re).first
    if matched.is_a?(Array)
      json['custom']['service_name.extracted'] = matched.compact.first.strip()
    else
      json['custom']['service_name.extracted'] = 'Not found for extraction'
    end
    return json
  end

  def fetch_log_entries(path='/log_entries')
    more = true
    while more
      response = self.class.get(path, @options)
      body = JSON.parse(response.body)
      body['log_entries'].each do |_json|
        json = process_json(_json)
        @log_entries_queue.push(json)
      end
      more = body['more']
      @options[:query][:offset] = body['offset'] + @query_limit if more == true
      self.flush_queue
    end
    self.flush_queue
  end
end

begin
  args = Docopt::docopt(doc)
rescue Docopt::Exit => e
  puts e.message
  exit(1)
end

pd = Pagerduty.new(args)
pd.fetch_log_entries
