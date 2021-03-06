require 'rubygems'

# Both isolate and bundler both break under passenger and rvm -- not sure why.
# But passenger's spawn process checks the .bundle files to determine load
# load paths, so we don't need these setup checks. Instead we create an 
# .rvmrc configuration file in this directory that specifies the appropriate
# rvm gemset to use for this application.

# require 'isolate/now'
# require 'bundler'
# Bundler.setup

# After modifying source code and the Gemfile, we do:
# 'bundle check' and 'bundle lock'.

require 'sinatra'
# require 'sass'
require 'logger'
require 'memcache'
require 'json'
require 'haml'
require 'tzinfo'
require 'net/https'
require 'uri'
require 'yaml'

# This is required to avoid warnings on OS X Server's libxml2 version
I_KNOW_I_AM_USING_AN_OLD_AND_BUGGY_VERSION_OF_LIBXML2 = true
require 'nokogiri'


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
  set :site_title, config['site_title']
  set :base_uri, config['base_uri']
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
  
  def debug
    false
  end
  
  def styles_for_font(font, day_class, event_class)
    family, size = font.split('-')
    family ||= 'Arial'
    family.gsub(/_/, ' ')
    size ||= '10pt'
    html = "<style type='text/css'>\n"
    html << ".#{day_class} {\n"
    html << " font-family: #{family};\n"
    html << " font-size: #{size};\n"
    html << " font-weight: bold;\n"
    html << " padding-top: #{size}\n"
    html << "}\n"
    html << "#day-0 {\n"
    html << " padding-top: 0px;\n"
    html << "}\n"
    html << "body, .#{event_class} {\n"
    html << " font-family: #{family};\n"
    html << " font-size: #{size};\n"
    html << " font-weight: normal;\n"
    html << "}\n"
    html << "</style>\n"
    html
  end
  
  def simple_format(text)
    text.
      gsub(/\r\n?/, "\n").
      gsub(/\n\n+/, "\n\n").
      gsub(/([^\n]\n)(?=[^\n])/, '<p>\1</p>')
  end
  
  def format_details(location, description)
    lines = [ ]
    lines << "Location: #{location}" unless location.nil?
    lines << description unless description.nil?
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
      output << ", " if !output.empty?
      output << to_timezone(start_time).strftime('%B %d, %Y')
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
  
  # "https://www.google.com/calendar/embed?height=600&amp;wkst=1&amp;bgcolor=%23FFFFFF&amp;src=kentfieldschools.org_mqupj17t11lobrd52otobpst3g%40group.calendar.google.com&amp;color=%232952A3&amp;src=kentfieldschools.org_f0hhqgo35s75flqaaiku0cse0s%40group.calendar.google.com&amp;color=%23A32929&amp;src=kentfieldschools.org_o6gfv0t236oiqa0lqcl8sfngss%40group.calendar.google.com&amp;color=%23BE6D00&amp;ctz=America%2FLos_Angeles"
  
  def gcal_embed_url(cals)
    path = "http://www.google.com/calendar/embed"
    qs = "?showTitle=0&showTz=0&height=600&wkst=1&bgcolor=#FFFFFF"
    cals.each do |cal|
      qs << "&src=#{calendar_id(cal)}&color=#{calendar_color(cal)}"
    end
    qs << "&ctz=#{options.tzname}"
    path + escape_qs(qs)
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
  # Convert the events into hashes and put them into memcache
  def load_calendar_from_feed(calendar_name, today)
    start_max = today + options.lookahead
    url_s = gcal_feed_url(calendar_name, true)
    query_s = "?sortorder=ascending&orderby=starttime&singleevents=true"
    query_s += "&start-min=#{today.strftime('%Y-%m-%d')}T00:00:00Z"
    query_s += "&start-max=#{start_max.strftime('%Y-%m-%d')}T23:59:00Z"
    logger.info("load #{url_s}#{query_s}") if debug

    # support per-calendar colors
    color = calendar_color(calendar_name)

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
    events = calendar.xpath('//xmlns:feed/xmlns:entry').map do |entry|
      summ = entry.at_xpath('xmlns:title').content
      desc = entry.at_xpath('xmlns:content').content
      desc = nil if desc.empty? || desc == '<p>&nbsp;</p>'
      tags = desc.nil? ? [] : desc.scan(/\#\w+/).map { |t| t[1,t.length-1] }
      location = entry.at_xpath('gd:where').attr('valueString')
      location = nil if !location.nil? && location.empty?
      gd_when = entry.at_xpath('gd:when') 
      gd_start = gd_when.attr('startTime')
      gd_end = gd_when.attr('endTime')
      all_day = !gd_start.match(/T\d\d:\d\d/)
      start_time = all_day ? Date.parse(gd_start) : DateTime.parse(gd_start)
      finish_time = all_day ? nil : DateTime.parse(gd_end)
      display_time = format_time_range(start_time, finish_time, all_day, true)
      uid = entry.at_xpath('gCal:uid').attr('value')
      {
        :uid => uid,
        :url => entry.at_xpath("xmlns:link[@type='text/html']").attr('href'),
        :summary     => summ,
        :description => desc,
        :location    => location,
        :tags        => tags,
        :all_day     => all_day,
        :start_time  => start_time,
        :finish_time => finish_time,
        :display_time  => display_time,
        :calendar_name => calendar_name,
        :color       => color
      }
    end
    uids = events.inject({}) { |h, e| h[e[:uid]] = e; h }
    { :title => title, :events => events, :uids => uids }
  end
  
  def fetch_calendar(calendar_name, today, days=0, limit=0, tags=[], refresh=false)
    data = cache.get(calendar_name)
    if refresh || data.nil?
      logger.info("cache miss") if debug
      data = load_calendar_from_feed(calendar_name, today)
      # store calendar for an hour
      cache.set(calendar_name, data, 3600)
    else
      logger.info("cache hit") if debug
    end
    if tags && !tags.empty?
      data[:events] = data[:events].select { |e| !(e[:tags] & tags).empty? }
    end
    # TODO: handle days, limit
      
    data
  end
  
  def escape_qs(s)
    URI.escape(s, /[ @#\/]/)
  end
  
  def get_data(cals, today, days, limit, tags, refresh, return_days=false)
    calendars = [ ]
    events = [ ]
    uids = { }

    # TODO: filter on tags
    all_cals = options.calendars.keys 
    if cals.include?('all')
      cals = all_cals 
    else
      cals = cals.delete_if { |cal| !all_cals.include?(cal) }
    end
    
    cals.each do |cal|    
      # TODO: Tidy, separate out, error handling support
      cal_data = fetch_calendar(cal, today, days, limit, tags, refresh)
      events += cal_data[:events]
      calendars << { :title => cal_data[:title], :name => cal }
    end
    calendars.sort! { |a, b| a[:title] <=> b[:title] }

    events = events.flatten.sort { |a,b| a[:start_time] <=> b[:start_time] }
    events.reject! { |e| (to_timezone(e[:start_time]) <=> today) < 0 }
    if limit > 0
      number_today = events.find_all { |e| to_timezone(e[:start_time]) === today }.size
      limit = number_today if number_today > limit
      events = events[0, limit] 
    end

    if return_days
      days = { }
      events.each do |e|
        day = to_timezone_date(e[:start_time])
        (days[day.strftime('%Y-%m-%d')] ||= [ ]) << e
      end
      day_list = days.keys.sort.map do |day|
        { :date => day, :display_date => format_day(day, today), :events => days[day] }
      end
      return {:calendars => calendars, :days => day_list}
    end
    return {:calendars => calendars, :events => events}
  end
  
  alias_method :h, :escape_html
end

# Routes

# Jsonp testing
get '/test' do
  haml :test, :layout => false
end

# Return webpage with upcoming events list 
# format=days (default) - list events grouped by day
# format=events - list events without day grouping
get '/' do
  @today = to_timezone_date(DateTime.now)
  @errors = [ ]
  cals = (params[:cals] || 'all').split(/,/)
  days = (params[:days] || options.lookahead).to_i
  limit = (params[:limit] || 0).to_i
  tags = (params[:tags] || '').split(/,/)
  font = (params[:font] || 'Verdana-12pt')
  refresh = params[:refresh]
  
  use_layout = false
  template_name = (params[:format] || 'days').to_sym
  case template_name
  when :days
    use_layout = true unless params[:layout] == 'f'
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
  @data = get_data(cals, @today, days, limit, tags, refresh, template_name == :days)
  @font_styles = styles_for_font(font, @day_class, @event_class) if use_layout
  layout_opts = use_layout ? { } : { :layout => false }
  haml template_name, layout_opts
end

# Return webpage with embedded multiple Google calendars
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
  @embed_src = gcal_embed_url(cals)

  calendars = [ ]
  cals.each do |cal| 
    cal_data = fetch_calendar(cal, @today, 0, 1, [], refresh)
    calendars << { :title => cal_data[:title], :name => cal }
  end
  calendars.sort! { |a, b| a[:title] <=> b[:title] }
  @data = { :calendars => calendars }
  @font_styles =<<EOSTYLE
  <style type='text/css'>
  body { 
    text-align: center;
    min-width: 850px;
    font-family: Arial, Helvetica, sans serif; }
  dd {
    margin-bottom: 1em;
  }
  div#container { 
    text-align: left;
    margin-left: auto;
    margin-right: auto;
    width: 820px;
    position: relative; }
  </style>
EOSTYLE

  haml :calendar
end

# Return event details
get '/events/:uid' do
  @uid = params[:uid]
  refresh = params[:refresh]
  @today = to_timezone_date(DateTime.now)
  @errors = [ ]
  calendars = [ ]
  options.calendars.keys.each do |cal|
    cal_data = fetch_calendar(cal, @today, options.lookahead, 0, [], refresh)
    calendars << { :title => cal_data[:title], :name => cal }
    @event ||= cal_data[:uids][@uid]
  end
  calendars.sort! { |a, b| a[:title] <=> b[:title] }
  @data = { :calendars => calendars }
  haml @event ? :event : :event_not_found
end

# Return jsonp callback function with all event data
get '/jsonp' do
  @today = to_timezone_date(DateTime.now)
  cals = (params[:cals] || 'all').split(/,/)
  days = (params[:days] || options.lookahead).to_i
  limit = (params[:limit] || 0).to_i
  tags = (params[:tags] || '').split(/,/)
  refresh = params[:refresh]

  data = get_data(cals, @today, days, limit, tags, refresh, true)
  callback = params[:callback] || 'gcalCallback'
  content_type :js
  "#{callback}(#{data.to_json})"
end

get '/simple.css' do
  content_type 'text/css'
  sass :simple
end

get '/stylesheet.css' do
  content_type 'text/css'
  sass :stylesheet
end
