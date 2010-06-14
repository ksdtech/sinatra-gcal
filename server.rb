require "rubygems"
require "bundler"
Bundler.setup

require 'sinatra'
require 'logger'
require 'memcache'
require 'ostruct'
require 'haml'
require 'sass'
require 'tzinfo'
require 'net/https'
require 'open-uri'
require 'uri'
require 'ri_cal'
require 'yaml'

# TODO: tag for #parented, #pta (meeting and special events, except parented)
# TODO: param for styled boxes or flat text (like schoolwires)
# TODO: #tbd flag
# TODO: param for separate color per site or not (i.e. pta has no color)
# TODO: click on event reveals javsacript, including link to orignal calendar event in new window

configure do
  config_file = File.expand_path(File.join(File.dirname(__FILE__)), 'config.yml')
  config = YAML.load_file(config_file)
  set :default_color, config['default_color']
  set :calendars, config['calendars']
  set :lookahead, config['lookahead']
  set :timezone, TZInfo::Timezone.get(config['timezone'])
  CACHE = MemCache.new('localhost:11211', :namespace => 'sinatra-gcal')
  LOGGER = Logger.new("sinatra.log")
end

helpers do
  def cache
    CACHE
  end
  
  def logger
    LOGGER
  end
  
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

  def gcal_embed_url(calendar_name)
    calendar_id = calendar_id(calendar_name)
    "http://www.google.com/calendar/hosted/kentfieldschools.org/embed?src=#{calendar_id}"
  end

  # Caching support
  # Fetching the ical feed, parsing and sorting takes time
  # Convert the events into OpenStructs and put them into memcache
  def load_calendar(calendar_name)
    uri = URI.parse(gcal_url(calendar_name))
    ical_string = ''
    open(uri.to_s) do |f|
      ical_string = f.read
    end
    calendar = RiCal.parse_string(ical_string).first
    title = calendar.x_properties['X-WR-CALNAME'].first.value
    occurrences = calendar.events.map do |e|
      e.occurrences(:starting => @today, :before => @today + options.lookahead)
    end.flatten.sort { |a,b| a.start_time <=> b.start_time }
    event_structs = occurrences.map do |e|
      OpenStruct.new(
        :uid => e.uid,
        :url => e.url,
        :summary => e.summary,
        :description => e.description,
        :tags => e.description.scan(/\#\w+/).map { |t| t[1,t.length-1] },
        :start_time => e.start_time,
        :finish_time => e.finish_time,
        :location => e.location,
        :calendar_name => calendar_name)
    end
    { :title => title, :events => event_structs }
  end
  
  def fetch_calendar(calendar_name, days=0, limit=0, refresh=false)
    data = cache.get(calendar_name)
    if refresh || data.nil?
      logger.info("cache miss")
      data = load_calendar(calendar_name)
      cache.set(calendar_name, data)
    else
      logger.info("cache hit")
    end
    # TODO: handle days and limit arguments
    data
  end

  alias_method :h, :escape_html
end

get '/embed' do
  cal = params[:cal]
  @embed_src = gcal_embed_url(cal)
  haml :embed
end

get '/' do
  all_cals = options.calendars.keys 
  @days = (params[:days] || options.lookahead).to_i
  limit = (params[:limit] || 0).to_i
  refresh = params[:refresh]
  template_name = (params[:style] || 'days').to_sym
  tags = (params[:tags] || '').split(/,/)
  cals = (params[:cals] || 'all').split(/,/)
  if cals.include?('all')
    cals = all_cals 
  else
    cals = cals.delete_if { |cal| !all_cals.include?(cal) }
  end
  @today = to_timezone_date(DateTime.now)
  @calendars = { }
  @events = [ ]
  @errors = [ ]
  cal_data = nil
  cals.each do |cal|    
    # TODO: Tidy, separate out, error handling support
    cal_data = fetch_calendar(cal, @days, limit, refresh)
    @calendars[cal] = cal_data[:title]
    @events += cal_data[:events]
  end
  
  @events = @events.flatten.sort { |a,b| a.start_time <=> b.start_time }
  @events.reject! { |e| (to_timezone(e.start_time) <=> @today) < 0 }
  if limit > 0
    number_today = @events.find_all { |e| to_timezone(e.start_time) === @today }.size
    limit = number_today if number_today > limit
    @events = @events[0, limit] 
  end
  if template_name == :days
    @days = { }
    @events.each do |e|
      d = to_timezone_date(e.start_time)
      day_key = d.strftime('%Y%m%d:%B %d, %Y')
      (@days[day_key] ||= [ ]) << e
    end
  end
  haml template_name
end

get '/stylesheet.css' do
  content_type 'text/css'
  sass :stylesheet
end
