#!/usr/bin/env ruby

require 'eventmachine'
require 'em-http-request'
require 'em-files'
require 'nokogiri'
require 'open-uri'
require 'open_uri_redirections'
require 'fileutils'
require 'active_support/core_ext/string'
require 'pathname'

MAX_CONNECTIONS = 5
FOLLOW_REDIRECT = [301, 302, 307]
MAX_FNAME_LEN   = 30
DEBUG = true

URL    = ARGV[0]
TARGET = ARGV[1]

class FunBot

  attr_reader :works

  def initialize(queue, images)
    @queue = queue
    @images = images
    @works = 0
  end

  def not_finished?; @works != 0 end

  def run
    return if @queue.empty?

    @queue.pop do |url|
      inc_work

      fname = URI(url).path.split('/').last
      return skip_step('Skipping missed filename') unless fname

      fext = File.extname(fname)
      return skip_step("Skipping missed extension for #{fname}") if fext.blank?

      bname = File.basename(fname, fext)[0..MAX_FNAME_LEN].gsub(/[^a-z0-9\-\.]+/i, '_')
      fname = bname + fext

      suffix = 0
      while @images.include?(fname)
        suffix += 1
        fname = bname + "-#{suffix}" + fext
      end
      @images << fname

      fpath = File.join(TARGET, fname)
      EM::File::open(fpath, 'wb'){ |f| download_file(url, f) }
    end
  end

  private

  def inc_work; @works += 1 end
  def dec_work; @works -= 1 end

  def download_file(url, file)
    puts("Downloading: #{url} to #{file.native.path}")
    request = EM::HttpRequest.new(url).get

    request.stream{ |chunk| file.write(chunk) }

    request.errback{ next_step(file) }

    request.callback do
      if FOLLOW_REDIRECT.include?(request.response_header.status)
        location = request.response_header.location
        puts("Redirecting to: #{location}")

        file.close
        file.reopen!

        download_file(location, file)
      else
        next_step(file, request.response_header.status)
      end
    end
  end

  def skip_step(msg)
    puts(msg)
    dec_work
    run
  end

  def next_step(file, status = nil)
    file.close
    # TODO: This should also be async
    File.delete(file.native.path) if !status || status != 200
    dec_work
    run
  end
end

@images = Pathname.glob(File.join(TARGET, '*')).select(&:file?).map{ |f| f.basename.to_s }
FileUtils.mkpath(TARGET) unless File.directory?(TARGET)

@bots = []

def done?
  @queue.empty? && !@bots.find(&:not_finished?)
end

def print_stat
  puts("Pending works: #{@queue.size} Bots active: #{@bots.count(&:not_finished?)}")
end

def get_image_urls
  host = URL.start_with?('http') ? URL : "http://#{URL}"
  html = open(host, :allow_redirections => :all)

  urls = Nokogiri::HTML(html).xpath("//img/@src").map(&:value)
  urls.map{ |u| u =~ /^(http|\/\/)/ ? u : File.join(host, u) }
end

EM.run do
  image_urls = get_image_urls

  @queue = EM::Queue.new
  @queue.push(*image_urls)

  print_stat if DEBUG

  1.upto(MAX_CONNECTIONS) do
    bot = FunBot.new(@queue, @images)
    bot.run
    @bots << bot
  end

  EventMachine::add_periodic_timer(1) do
    print_stat if DEBUG
    EventMachine.stop if done?
  end
end
