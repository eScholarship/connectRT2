
###################################################################################################
# Use the right paths to everything, basing them on this script's directory.
def getRealPath(path) Pathname.new(path).realpath.to_s; end
$homeDir    = ENV['HOME'] or raise("No HOME in env")
$scriptDir  = getRealPath "#{__FILE__}/.."
$subiDir    = getRealPath "#{$scriptDir}/.."
$espylib    = getRealPath "#{$subiDir}/lib/espylib"
$erepDir    = getRealPath "#{$subiDir}/xtf-erep"
$arkDataDir = getRealPath "#{$erepDir}/data"
$controlDir = getRealPath "#{$erepDir}/control"
$jscholDir  = getRealPath "#{$homeDir}/eschol5/jschol"

# Go to the right URLs for the front-end+api and submission systems
$escholServer = ENV['ESCHOL_FRONTEND_URL'] || raise("missing env ESCHOL_FRONTEND_URL")
$submitServer = ENV['ESCHOL_SUBMIT_URL'] || raise("missing env ESCHOL_SUBMIT_URL")

###################################################################################################
# External code modules
require 'date'
require 'httparty'
require 'json'
require 'mail'
require 'nokogiri'
require 'pp'
require 'sinatra'
require 'time'
require_relative "./rest.rb"

# Flush stdout after each write
STDOUT.sync = true

 # Compress things that can benefit
configure do
  set show_exceptions: false

  use Rack::Deflater,
    :include => %w{application/javascript text/html text/xml text/css application/json image/svg+xml},
    :if => lambda { |env, status, headers, body|
      # advice from https://www.itworld.com/article/2693941/cloud-computing/
      #               why-it-doesn-t-make-sense-to-gzip-all-content-from-your-web-server.html
      return headers["Content-Length"].to_i > 1400
    }
end

###################################################################################################
# Simple up/down check
get "/chk" do
  "connectRT2 running\n"
end

#################################################################################################
def sendErrorEmail(requestURL, subject, exc)
  textBody = "Unhandled exception: #{exc.message}\n" +
             "connectRT2 URL: #{request.url}\n" +
             "connectRT2 backtrace:\n" +
             "\t#{exc.backtrace.join("\n\t")}\n"
  textBody.gsub! %r{/apps/eschol/.*/gems/([^/]+)}, '...gems/\1/'
  textBody.gsub! %r{/apps/eschol/}, ''
  textBody.gsub! "<", "&lt;"
  textBody.gsub! ">", "&gt;"
  htmlBody = textBody.gsub("\n", "<br/>")
  mail = Mail.new do
    from     "eschol@#{`/bin/hostname --fqdn`.strip}"
    to       "r.c.martin.haye@ucop.edu, Mahjabeen.Yucekul@ucop.edu"
    subject  "#{$submitServer =~ /stg/ ? "Stage" : "Production"} #{subject}"
    text_part do
      content_type 'text/plain; charset=UTF-8'
      body         textBody
    end
    html_part do
      content_type 'text/html; charset=UTF-8'
      body         htmlBody
    end
  end
  begin
    mail.deliver
  rescue Exception => e
    puts "Error processing error email to: #{e}"
  end
end

#################################################################################################
# Error handling - include call stack for upper layers to report
error 500 do
  puts "Exception URL: #{request.url}"
  sendErrorEmail(request.url, "RT2 error", env['sinatra.error'])
  content_type "text/plain"
  return "Internal server error"
end

###################################################################################################
# When called from the command line, the program acts as a web server, or can retry a meta update.
if ARGV.delete('retryMetaUpdate')
  # Run it this way:
  # cd ~/subi/connectRT2 && source config/env.sh && ls failedUpdates/ | extract 'qt\w{8}' | xargs bundle exec ruby connectRT2.rb retryMetaUpdate
  retryMetaUpdate(ARGV)
  exit 0 # Need to explicitly exit the program so Sinatra doesn't take over.
elsif ARGV.delete('retryHolidayUpdate')
  retryHolidayUpdate(ARGV)
  exit 0 # Need to explicitly exit the program so Sinatra doesn't take over.
else
  # Do nothing and allow Sinatra to take the stage
end
