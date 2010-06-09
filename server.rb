require "rubygems"
require "bundler"
Bundler.setup

require 'sinatra'
require 'tzinfo'
require 'net/https'
require 'open-uri'
require 'uri'
require 'ri_cal'
require 'yaml'

configure do
  config_file = File.expand_path(File.join(File.dirname(__FILE__)), 'config.yml')
  config = YAML.load_file(config_file)
  set :default_color, config['default_color']
  set :calendars, config['calendars']
  set :lookahead, config['lookahead']
  set :timezone, TZInfo::Timezone.get(config['timezone'])
end

helpers do
  def format_time_range(start_time, end_time)
    output = format_time(start_time)
    output << " &mdash; #{format_time(end_time)}" unless end_time.nil?
    output << ", #{to_timezone(start_time).strftime('%d %b %Y')}"
  end
  
  def format_time(datetime)
    to_timezone(datetime).strftime('%I:%M%p')
  end
  
  def to_timezone(datetime)
    options.timezone.utc_to_local(datetime.new_offset(0))
  end
  
  def to_timezone_date(datetime)
    current = to_timezone(datetime)
    Date.new(current.year, current.month, current.day)
  end
  
  def calendar_id(calendar_name)
    options.calendars[calendar_name]['calendar_id']
  end

  def private_key(calendar_name)
    options.calendars[calendar_name]['private_key']
  end

  def calendar_private?(calendar_name)
    !options.calendars[calendar_name]['private_key'].empty? rescue false
  end

  def calendar_color(calendar_name)
    options.calendars[calendar_name]['color'] rescue options.default_color
  end
  
  def gcal_url(calendar_name)
    calendar_id = calendar_id(calendar_name)
    calendar_private?(calendar_name) ?
      "https://www.google.com/calendar/ical/#{calendar_id}/private-#{private_key(calendar_name)}/basic.ics" :
      "http://www.google.com/calendar/ical/#{calendar_id(calendar_name)}/public/basic.ics"
  end
  
  def gcal_feed_url(calendar_name)
    calendar_id = calendar_id(calendar_name)
    calendar_private?(calendar_name) ? 
      "https://www.google.com/calendar/feeds/#{calendar_id}/private-#{private_key(calendar_name)}/basic" :
      "http://www.google.com/calendar/feeds/#{calendar_id}/public/basic"
  end
  
  alias_method :h, :escape_html
end

# TODO: Add caching support

get '/' do
  all_cals = options.calendars.keys 
  limit = (params[:count] || 0).to_i
  days = (params[:days] || options.lookahead).to_i
  cals = params[:cals] || 'all'
  cals = cals.split(/,/)
  if cals.include?('all')
    cals = all_cals 
  else
    cals = cals.delete_if { |cal| !all_cals.include?(cal) }
  end
  @today = to_timezone_date(DateTime.now)
  @calendars = { }
  @events = [ ]
  @errors = [ ]
  s = ''
  cals.each do |cal|    
    # TODO: Tidy, separate out, error handling support
    uri = URI.parse(gcal_url(cal))
    ical_string = ''
    begin
      open(uri.to_s) do |f|
        ical_string = f.read
      end
    rescue
      @errors << $!
    end
    components = RiCal.parse_string ical_string
    calendar = components.first
    @calendars[cal] = calendar.x_properties['X-WR-CALNAME'].first.value
    cal_events = calendar.events.map do |e|
      e.occurrences(:starting => @today, :before => @today + days)
    end.flatten
    cal_events.each do |e|
      e.comment = cal
    end
    @events += cal_events
  end
  @events = @events.flatten.sort { |a,b| a.start_time <=> b.start_time }
  @events.slice!(0, limit) if limit > 0  
  haml :events
end

get '/stylesheet.css' do
  content_type 'text/css'
  sass :stylesheet
end
