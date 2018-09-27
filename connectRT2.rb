
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
require 'nokogiri'
require 'pp'
require 'sinatra'
require 'time'
require_relative "./rest.rb"
require_relative "./deposit.rb"

# Flush stdout after each write
STDOUT.sync = true

 # Compress things that can benefit
use Rack::Deflater,
  :include => %w{application/javascript text/html text/xml text/css application/json image/svg+xml},
  :if => lambda { |env, status, headers, body|
    # advice from https://www.itworld.com/article/2693941/cloud-computing/
    #               why-it-doesn-t-make-sense-to-gzip-all-content-from-your-web-server.html
    return headers["Content-Length"].to_i > 1400
  }

###################################################################################################
# Simple up/down check
get "/chk" do
  "connectRT2 running\n"
end