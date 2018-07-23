
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

###################################################################################################
# External code modules
require 'nokogiri'
require 'pp'
require 'httparty'
require 'sinatra'
require_relative "./rest.rb"

