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
require 'uri'
require 'nokogiri'
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
  set :tzname, config['timezone']
  set :timezone, TZInfo::Timezone.get(config['timezone'])
  set :apps_domain, config['apps_domain']
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
  
  def simple_format(text)
    text.
      gsub(/\r\n?/, "\n").
      gsub(/\n\n+/, "\n\n").
      gsub(/([^\n]\n)(?=[^\n])/, '<p>\1</p>')
  end
  
  def format_details(location, description)
    lines = [ ]
    lines << "Location: #{location}" unless location.nil? || location.empty?
    lines << description unless description.nil? || description.empty?
    return "No details available" if lines.empty?
    lines.join("<br/>")
  end
  
  def format_day(date_string, today)
    tomorrow = today + 1
    date = Date.parse(date_string)
    case date
    when today
      return 'Today'
    when tomorrow
      return 'Tomorrow'
    else
      return date.strftime('%B %d, %Y')
    end
  end
  
  def format_time_range(start_time, end_time, all_day, show_date=true)
    output = ''
    if !all_day
      output = format_time(start_time)
      output << " &mdash; #{format_time(end_time)}" unless end_time.nil?
    end
    if show_date
      date_part = to_timezone(start_time).strftime('%d %b %Y')
      output << ", #{date_part}"
    end
    output
  end
  
  def format_time(datetime)
    to_timezone(datetime).strftime('%I:%M %p').gsub(/^0/, '')
  end
  
  def to_timezone(datetime)
    return datetime unless datetime.is_a?(DateTime)
    options.timezone.utc_to_local(datetime.new_offset(0))
  end
  
  def to_timezone_date(datetime)
    return datetime unless datetime.is_a?(DateTime)
    current = options.timezone.utc_to_local(datetime.new_offset(0))
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
    color = options.calendars[calendar_name]['color'] rescue options.default_color
    color.upcase
  end
  
  def gcal_embed_url(cals)
    url = "http://www.google.com/calendar/hosted/#{options.apps_domain}/embed?showTitle=0&showTz=0&height=600&wkst=1&bgcolor=#FFFFFF"
    cals.each do |cal|
      url << "&src=#{calendar_id(cal)}&color=#{calendar_color(cal)}"
    end
    url << "&ctz=#{options.tzname}"
    url
  end
  
  def gcal_ical_url(calendar_name)
    calendar_id = calendar_id(calendar_name)
    calendar_private?(calendar_name) ?
      "https://www.google.com/calendar/ical/#{calendar_id}/private-#{private_key(calendar_name)}/basic.ics" :
      "http://www.google.com/calendar/ical/#{calendar_id(calendar_name)}/public/basic.ics"
  end
  
  def gcal_feed_url(calendar_name, full=false)
    calendar_id = calendar_id(calendar_name)
    feed_name = full ? 'full' : 'basic'
    calendar_private?(calendar_name) ? 
      "https://www.google.com/calendar/feeds/#{calendar_id}/private-#{private_key(calendar_name)}/#{feed_name}" :
      "http://www.google.com/calendar/feeds/#{calendar_id}/public/#{feed_name}"
  end

  # Caching support
  # Convert the events into OpenStructs and put them into memcache
  def load_calendar_from_feed(calendar_name)
    start_max = @today + options.lookahead
    url_s = gcal_feed_url(calendar_name, true)
    query_s = "?sortorder=ascending&orderby=starttype&singleevents=true&futureevents=true"
    query_s += "&start-max=#{start_max.strftime('%Y-%m-%d')}T23:59:00Z"

    # No support for ssl_verify_mode?
    # open(url_s, :ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE) do |f|
    #   xml_string = f.read
    # end

    url = URI.parse(url_s)
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = url.scheme == 'https'
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    req = Net::HTTP::Get.new(url.path + query_s)
    res = http.start { |h| h.request(req) }
    xml_string = res.body

    calendar = Nokogiri::XML.parse(xml_string)
    title = calendar.at_xpath('//xmlns:feed/xmlns:title').content
    event_structs = calendar.xpath('//xmlns:feed/xmlns:entry').map do |entry|
      summ = entry.at_xpath('xmlns:title').content
      desc = entry.at_xpath('xmlns:content').content
      desc = '' if desc == '<p>&nbsp;</p>'
      gd_when = entry.at_xpath('gd:when') 
      gd_start = gd_when.attr('startTime')
      gd_end = gd_when.attr('endTime')
      all_day = !gd_start.match(/T\d\d:\d\d/)
      OpenStruct.new(
        :uid => entry.at_xpath('gCal:uid').attr('value'),
        :url => entry.at_xpath("xmlns:link[@type='text/html']").attr('href'),
        :summary => summ,
        :description => desc,
        :tags => desc.scan(/\#\w+/).map { |t| t[1,t.length-1] },
        :location => entry.at_xpath('gd:where').attr('valueString'),
        :all_day => all_day,
        :start_time => all_day ? Date.parse(gd_start) : DateTime.parse(gd_start),
        :finish_time => all_day ? nil : DateTime.parse(gd_end),
        :calendar_name => calendar_name)
    end
    { :title => title, :events => event_structs }
  end
  
  def fetch_calendar(calendar_name, days=0, limit=0, tags=[], refresh=false)
    data = cache.get(calendar_name)
    if refresh || data.nil?
      logger.info("cache miss")
      data = load_calendar_from_feed(calendar_name)
      cache.set(calendar_name, data)
    else
      logger.info("cache hit")
    end
    # TODO: handle days, limit, tags arguments
    data
  end
  
  def embed_escape(s)
    escape_html(s).gsub(/\#/, '%23').gsub(/\@/, '%40')
  end

  alias_method :h, :escape_html
end

get '/calendar' do
  @today = to_timezone_date(DateTime.now)
  @errors = [ ]
  refresh = params[:refresh]
  all_cals = options.calendars.keys 
  cals = (params[:cals] || 'all').split(/,/)
  if cals.include?('all')
    cals = all_cals 
  else
    cals = cals.delete_if { |cal| !all_cals.include?(cal) }
  end
  @calendars = { }
  cals.each do |cal| 
    cal_data = fetch_calendar(cal, 0, 1, [], refresh)
    @calendars[cal_data[:title]] = cal
  end
  @embed_src = gcal_embed_url(cals)
  haml :calendar
end

get '/' do
  @today = to_timezone_date(DateTime.now)
  @errors = [ ]
  refresh = params[:refresh]
  days = (params[:days] || options.lookahead).to_i
  limit = (params[:limit] || 0).to_i
  use_layout = (params[:layout] || 'f') == 't'
  template_name = (params[:format] || 'days').to_sym
  case template_name
  when :embed
    use_layout = true
  when :days
    # pass
  when :events
    # pass
  else
    raise RuntimeError, "invalid style"
  end
  css_style = (params[:style] || 'sw')
  if css_style == 'sw'
    @container_class = 'SW-Calendar-Block-Container'
    @day_class   = 'SW-Calendar-Block-Date'
    @event_class = 'SW-Calendar-Block-Event-Container'
    @time_class  = 'SW-Calendar-Block-Time'
    @title_class = 'SW-Calendar-Block-Title'
  else
    @container_class = 'contents'
    @day_class   = 'day'
    @event_class = 'event'
    @time_class  = 'time'
    @title_class = 'title'
  end
  @calendars = { }
  @events = [ ]
  
  # TODO: filter on tags
  tags = (params[:tags] || '').split(/,/)
  all_cals = options.calendars.keys 
  cals = (params[:cals] || 'all').split(/,/)
  if cals.include?('all')
    cals = all_cals 
  else
    cals = cals.delete_if { |cal| !all_cals.include?(cal) }
  end
  cals.each do |cal|    
    # TODO: Tidy, separate out, error handling support
    cal_data = fetch_calendar(cal, days, limit, tags, refresh)
    @calendars[cal_data[:title]] = cal
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
      day = to_timezone_date(e.start_time)
      (@days[day.strftime('%Y-%m-%d')] ||= [ ]) << e
    end
  end
  layout_opts = use_layout ? { } : { :layout => false }
  haml template_name, layout_opts
end

get '/simple.css' do
  content_type 'text/css'
  sass :simple
end

get '/stylesheet.css' do
  content_type 'text/css'
  sass :stylesheet
end

