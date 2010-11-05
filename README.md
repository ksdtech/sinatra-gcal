Sinatra GCal
============

**Note:** Hack and play, but beware: this is beta code.

Show off your Google Calendar in a nifty, Sinatra-powered events page.

![Sinatra GCal Example](http://imgur.com/odgyR.png)

See a demo running at [http://christchurch.events.geek.nz](http://christchurch.events.geek.nz)

Setting up
----------

Install requirements with `bundle install`.

Copy `config.example.yml` to `config.yml`, adjust as you need.

Run with `ruby server.rb` (or `shotgun server.rb`).

Configuration
-------------

You can set the following in `config.yml`.

* `gcal` - the identifier for your public Google Calendar (can be found under calendar sharing options, often `xxxxx@group.calendar.google.com`)
* `lookahead` - how many days in the future you'd like to display (eg. `30`)
* `timezone` - a TZInfo-compatible timezone (eg. `UTC` or `Pacific/Auckland`)

Running Live
------------

If you're using Passenger, a `config.ru` like this will do nicely:

    require 'rubygems'
    require 'sinatra'

    set :environment, :production
    disable :run

    require 'haml'
    require 'server'

    run Sinatra::Application
    
Kentfield Fork Changes
----------------------

I've implemented a few enhancements for use in our school district.

* Support for mulitple calendars, each in a different color.  Calendars are specified in a yaml configuration file read on startup.
* Cache system that uses memcached.
* Jsonp format for use with client-side Javascript.

See client_side.js for how the calendar json feed is used on our Schoolwires client site.

--Peter Zingg, github.com/ksdtech
