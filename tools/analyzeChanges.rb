#!/usr/bin/env ruby

# Use bundler to keep dependencies local
require 'rubygems'
require 'bundler/setup'

###################################################################################################
# Use the right paths to everything, basing them on this script's directory.
def getRealPath(path) Pathname.new(path).realpath.to_s; end
$homeDir    = ENV['HOME'] or raise("No HOME in env")
$scriptDir  = getRealPath "#{__FILE__}/.."
$subiDir    = getRealPath "#{$scriptDir}/../.."
$espylib    = getRealPath "#{$subiDir}/lib/espylib"
$erepDir    = getRealPath "#{$subiDir}/xtf-erep"
$arkDataDir = getRealPath "#{$erepDir}/data"
$controlDir = getRealPath "#{$erepDir}/control"
$jscholDir  = getRealPath "#{$homeDir}/eschol5/jschol"

###################################################################################################
# External code modules
require 'cgi'
require 'date'
require 'dbm'
require 'httparty'
require 'nokogiri'
require 'pp'
require 'sqlite3'
require 'time'

# Flush stdout after each write
STDOUT.sync = true

# We need to look up IDs in the OAP database.
$oapDb = SQLite3::Database.new("#{$subiDir}/oapImport/oap.db")
$oapDb.busy_timeout = 60000

# We'll need to look things up in the arks database, so open it now.
$arkDb = SQLite3::Database.new("#{$controlDir}/db/arks.db")
$arkDb.busy_timeout = 30000

$apiHost = ENV['ELEMENTS_API_URL'] || raise("missing env ELEMENTS_API_URL")

# Put pub info in a persistent DB so we can be resumable
$pubInfo = DBM.open("#{$scriptDir}/cache/pubInfo", 0644, DBM::WRCREAT)
$oapToPub = DBM.open("#{$scriptDir}/cache/oapToPub", 0644, DBM::WRCREAT)
$arkToRT2Pub = DBM.open("#{$scriptDir}/cache/arkToRT2Pub", 0644, DBM::WRCREAT)

###################################################################################################
def getInfo(pubID)
  Marshal.load($pubInfo[pubID])
end

###################################################################################################
def anyExtRecords(info)
  info[:ids].keys.any?{|k| !(k =~ /dspace|c-/) }
end

###################################################################################################
# The main routine

arkInfo = Hash.new{|h,k| h[k] = {}}
pubXfer = Hash.new{|h,k| h[k] = []}
$pubInfo.each { |pubID, idStr|
  info = getInfo(pubID)
  oldEschol = info.dig(:ids, 'c-eschol-id', 0)
  oapID = info.dig(:ids, 'c-inst-1', 0)
  if !oldEschol && oapID
    oldEschol = $oapDb.get_first_value("SELECT campus_id FROM ids WHERE campus_id like \'%eschol%\' and oap_id = ?", oapID)
  end

  newEschol = info.dig(:ids, 'dspace', 0)

  xferVal = (oldEschol ? "1" : "0") + (newEschol ? "1" : "0")
  pubXfer[xferVal] << pubID

  next unless xferVal == "10"

  oldEschol =~ /qt\w{8}/ and arkInfo[$&][:rt1] = pubID
  newEschol =~ /qt\w{8}/ and arkInfo[$&][:rt2] = pubID
}

pubXfer.each { |k, v|
  puts "size pubXfer[#{k}] = #{pubXfer[k].size}"
}

nSameJoin = nNewJoin = nTotallyNew = nDisappeared = nKilled =
  nDifferentJoin = nDifferentJoin2 = nDifferentJoin3 = nLeftDupe = nFixedDupe = nNewDupe = 0
arkInfo.keys.sort.each { |ark|
  info = arkInfo[ark]
  pub1, pub2 = info[:rt1], info[:rt2]
  if pub1 == pub2
    nSameJoin += 1
  elsif pub2 && !pub1
    if anyExtRecords(getInfo(pub2))
      nNewJoin += 1
    else
      nTotallyNew += 1
    end
  elsif pub1 && !pub2
    if getInfo(pub1).dig(:ids, 'dspace')
      nDifferentJoin3 += 1
    elsif anyExtRecords(getInfo(pub1))
      nDisappeared += 1
      puts "disappeared: ark=#{ark} pub1=#{pub1}"
    else
      nKilled += 1
    end
  elsif pub1 && pub2
    if anyExtRecords(getInfo(pub1))
      if anyExtRecords(getInfo(pub2))
        nDifferentJoin += 1
      else
        if getInfo(pub1).dig(:ids, 'dspace')
          nDifferentJoin2 += 1
          #puts "diffjoin2: ark=#{ark} pub1=#{pub1} pub2=#{pub2}"
        else
          nLeftDupe += 1
          #puts "left dupe: ark=#{ark} pub1=#{pub1} pub2=#{pub2}"
        end
      end
    else
      if anyExtRecords(getInfo(pub2))
        nFixedDupe += 1
      else
        nNewDupe += 1
      end
    end
  else
    raise("impossible")
  end
}

puts "nSameJoin=#{nSameJoin}"
puts "nNewJoin=#{nNewJoin}"
puts "nTotallyNew=#{nTotallyNew}"
puts "nDisappeared=#{nDisappeared}"
puts "nKilled=#{nKilled}"
puts "nDifferentJoin=#{nDifferentJoin}"
puts "nDifferentJoin2=#{nDifferentJoin2}"
puts "nDifferentJoin3=#{nDifferentJoin3}"
puts "nLeftDupe=#{nLeftDupe}"
puts "nFixedDupe=#{nFixedDupe}"
puts "nNewDupe=#{nNewDupe}"