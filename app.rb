require 'sinatra'
require 'httparty'
require 'json'
require 'yaml'
require 'rexml/document'
require 'time'

# ---------------------------------------------------------------------------
# Fetcher base — normalised result schema:
#   { name:, url:, indicator:, description:, active_events:, upcoming_count:,
#     priority:, error: }
#
# indicator values : "none" | "minor" | "major" | "critical" | "unknown"
# active_events    : [{ name:, status:, type: "incident"|"maintenance" }]
# upcoming_count   : integer (scheduled but not yet started maintenances)
# ---------------------------------------------------------------------------

class AtlassianFetcher
  def self.fetch(name, config, priority)
    url  = config['url']
    resp = HTTParty.get(
      "#{url}/api/v2/summary.json",
      headers: { 'User-Agent' => 'status-page-aggregator/1.0' },
      timeout: 10
    )
    raise "HTTP #{resp.code}" unless resp.success?

    data = JSON.parse(resp.body)

    active_events = []

    # Unresolved incidents
    (data['incidents'] || []).each do |inc|
      next if inc['status'] == 'resolved'
      active_events << {
        name:   inc['name'],
        status: inc['status'],
        type:   'incident'
      }
    end

    # In-progress scheduled maintenances
    upcoming_count = 0
    (data['scheduled_maintenances'] || []).each do |m|
      case m['status']
      when 'in_progress'
        active_events << {
          name:   m['name'],
          status: m['status'],
          type:   'maintenance'
        }
      when 'scheduled'
        upcoming_count += 1
      end
    end

    {
      name:           name,
      url:            config['link'] || url,
      indicator:      data.dig('status', 'indicator') || 'unknown',
      description:    data.dig('status', 'description') || '',
      active_events:  active_events,
      upcoming_count: upcoming_count,
      priority:       priority,
      error:          nil
    }
  rescue => e
    error_result(name, config['link'] || config['url'], priority, e.message)
  end

  def self.error_result(name, url, priority, msg)
    { name: name, url: url, indicator: 'unknown', description: '',
      active_events: [], upcoming_count: 0, priority: priority, error: msg }
  end
end

class GoogleCloudFetcher
  GEMINI_KEYWORDS = %w[Gemini Vertex AI\ Platform Bard].freeze

  def self.fetch(name, config, priority)
    url    = config['url']
    filter = config['filter']

    resp = HTTParty.get(
      "#{url}/incidents.json",
      headers: { 'User-Agent' => 'status-page-aggregator/1.0' },
      timeout: 10
    )
    raise "HTTP #{resp.code}" unless resp.success?

    all_incidents = JSON.parse(resp.body)

    # Active = not yet ended
    active = all_incidents.select { |inc| inc['end'].nil? }

    # Apply product filter for Gemini
    if filter == 'gemini'
      active = active.select do |inc|
        products = (inc['affected_products'] || []).map { |p| p['title'] }
        products.any? { |p| GEMINI_KEYWORDS.any? { |kw| p.include?(kw) } }
      end
    end

    active_events = active.map do |inc|
      {
        name:   inc['external_desc'] || inc['id'],
        status: inc.dig('updates', 0, 'status') || 'active',
        type:   'incident'
      }
    end

    # Derive overall indicator from worst active severity
    severities = active.map { |inc| inc['severity'] }.compact
    indicator = if severities.include?('high')
      'major'
    elsif severities.any? { |s| %w[medium low].include?(s) }
      'minor'
    elsif active.empty?
      'none'
    else
      'minor'
    end

    description = indicator == 'none' ? 'All Systems Operational' : "#{active.size} active incident(s)"

    {
      name:           name,
      url:            config['link'] || url,
      indicator:      indicator,
      description:    description,
      active_events:  active_events,
      upcoming_count: 0,
      priority:       priority,
      error:          nil
    }
  rescue => e
    error_result(name, config['link'] || config['url'], priority, e.message)
  end

  def self.error_result(name, url, priority, msg)
    { name: name, url: url, indicator: 'unknown', description: '',
      active_events: [], upcoming_count: 0, priority: priority, error: msg }
  end
end

class AwsFetcher
  RSS_URL        = 'https://status.aws.amazon.com/rss/all.rss'.freeze
  REGION_PATTERN = /((?:us|eu|ap|sa|ca|me|af|il)-[a-z]+-\d+)\z/.freeze

  # Title keyword → indicator severity
  TITLE_SEVERITY = {
    /service disruption/i  => 'major',
    /service impact/i      => 'minor',
    /performance issues/i  => 'minor',
    /latency/i             => 'minor',
    /elevated error/i      => 'minor',
    /informational/i       => 'minor'
  }.freeze

  def self.fetch(name, config, priority)
    resp = HTTParty.get(
      RSS_URL,
      headers: { 'User-Agent' => 'status-page-aggregator/1.0' },
      timeout: 10
    )
    raise "HTTP #{resp.code}" unless resp.success?

    doc   = REXML::Document.new(resp.body)
    items = REXML::XPath.match(doc, '//item')

    # Deduplicate by incident ID (guid path fragment) and skip resolved items
    seen       = {}
    active_raw = []

    items.each do |item|
      title = item.elements['title']&.text.to_s
      next if title.match?(/\[resolved\]|resolved:/i)

      guid       = item.elements['guid']&.text.to_s
      incident_id = guid.split('#').last.to_s.split('_').first

      next if incident_id.empty? || seen[incident_id]
      seen[incident_id] = true

      pub_date = Time.parse(item.elements['pubDate']&.text.to_s) rescue nil
      next if pub_date && (Time.now.utc - pub_date) > 48 * 3600

      region = incident_id.match(REGION_PATTERN)&.captures&.first
      active_raw << { title: title, pub_date: pub_date, region: region }
    end

    active_events = active_raw.map do |ev|
      display_name = ev[:region] ? "#{ev[:title]} [#{ev[:region]}]" : ev[:title]
      { name: display_name, status: 'active', type: 'incident' }
    end

    # Derive worst indicator
    indicator = active_raw.reduce('none') do |worst, ev|
      sev = TITLE_SEVERITY.find { |pattern, _| ev[:title].match?(pattern) }&.last || 'minor'
      [worst, sev].min_by { |s| %w[major minor none].index(s) || 99 }
    end

    description = indicator == 'none' ? 'All Systems Operational' : "#{active_events.size} active incident(s)"

    {
      name:           name,
      url:            config['link'] || config['url'],
      indicator:      indicator,
      description:    description,
      active_events:  active_events,
      upcoming_count: 0,
      priority:       priority,
      error:          nil
    }
  rescue => e
    { name: name, url: config['link'] || config['url'], indicator: 'unknown', description: '',
      active_events: [], upcoming_count: 0, priority: priority, error: e.message }
  end
end

FETCHERS = {
  'atlassian'    => AtlassianFetcher,
  'google_cloud' => GoogleCloudFetcher,
  'aws'          => AwsFetcher
}.freeze

# ---------------------------------------------------------------------------
# Sinatra app
# ---------------------------------------------------------------------------

class StatusPageAggregator < Sinatra::Base
  configure do
    set :status_pages, YAML.load_file('config/status_pages.yml')
  end

  get '/styles.css' do
    scss :styles
  end

  get '/' do
    erb :index
  end

  get '/statuses' do
    content_type :json
    fetch_all_statuses.to_json
  end

  private

  def fetch_all_statuses
    config  = settings.status_pages
    results = []

    %w[primary secondary].each do |priority|
      (config[priority] || {}).each do |name, svc|
        fetcher = FETCHERS[svc['type']] || AtlassianFetcher
        results << fetcher.fetch(name, svc, priority)
      end
    end

    results
  end
end
