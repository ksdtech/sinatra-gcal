require 'rubygems'
require 'sinatra'

set :environment, :production
disable :run

require 'server'

log = File.new("sinatra.log", "a+")
$stdout.reopen(log)
$stderr.reopen(log)

run Sinatra::Application
