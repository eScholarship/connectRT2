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
require 'zlib'

require_relative "#{$espylib}/xmlutil.rb"

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
  pubID or return nil
  Marshal.load($pubInfo[pubID])
end

###################################################################################################
def anyExtRecords(info)
  info or return false
  info[:ids].keys.any?{|k| !(k =~ /dspace|c-|doi/) }
end

###################################################################################################
def pubURL(pubID, ext)
  pubID or return
  base = ENV['ELEMENTS_UI_URL'] || raise("missing env ELEMENTS_UI_URL")
  "=HYPERLINK(\"#{base}/viewobject.html?cid=1&id=#{pubID}\",\"#{pubID}#{ext ? "" : " orphan"}\")"
end

###################################################################################################
def arkURL(ark)
  ark or return
  base = ENV['ESCHOL_FRONTEND_URL'] || raise("missing env ESCHOL_FRONTEND_URL")
  "=HYPERLINK(\"#{base}/uc/item/#{ark.sub(/^qt/,'')}\",\"#{ark}\")"
end

###################################################################################################
# The main routine

pubMain     = Hash.new { |h,k| h[k] = [] }
pubXfer     = Hash.new { |h,k| h[k] = [] }
pubScheme   = Hash.new { |h,k| h[k] = [] }
pubToRT1Ark = Hash.new { |h,k| h[k] = [] }
pubToRT2Ark = Hash.new { |h,k| h[k] = [] }
pubToAuth   = Hash.new { |h,k| h[k] = [] }
pubToAuthHash = Hash.new { |h,k| h[k] = [] }
pubToSugg   = Hash.new { |h,k| h[k] = [] }
rt1ArkToPub = Hash.new { |h,k| h[k] = [] }
rt2ArkToPub = Hash.new { |h,k| h[k] = [] }

$pubInfo.each { |pubID, idStr|
  info = getInfo(pubID)

  # Did this pub have an eschol record in RT1?
  #oldEschol = Set.new((info.dig(:ids, 'c-eschol-id') || []).map { |fullArk|
  #  fullArk =~ /qt\w{8}/ or raise
  #  $&
  #})
  oldEschol = Set.new
  (info.dig(:ids, 'c-inst-1') || []).each { |oapID|
    $oapDb.execute(
      "SELECT campus_id FROM ids WHERE campus_id like \'%eschol%\' AND oap_id = ?", oapID) { |row|
        row[0] =~ /qt\w{8}/ or raise
        oldEschol << $&
      }
  }
  $arkDb.execute("SELECT id FROM arks WHERE source = 'elements' AND external_id = '#{pubID}'") { |row|
    row[0] =~ /qt\w{8}/ or raise
    oldEschol << $&
  }
  $oapDb.execute("SELECT eschol_ark FROM eschol_equiv WHERE pub_id = '#{pubID}'") { |row|
    row[0] =~ /qt\w{8}/ or raise
    oldEschol << $&
  }
  oldEschol = oldEschol.empty? ? nil : oldEschol.sort.to_a

  # Does it have an eschol record in RT2?
  newEschol = info.dig(:ids, 'dspace')
  newEschol and newEschol.sort!

  # Determine all the kinds of IDs on this pub
  schemes = Set.new(info[:ids].map { |scheme, id| scheme =~ /eschol/ ? nil : scheme }.compact)

  # Classify the RT status of this pub
  rtStatus = (!oldEschol && !newEschol) ? "non-RT" :
             ( oldEschol && !newEschol) ? "dropped" :
             (!oldEschol &&  newEschol) ? "new" :
             ( oldEschol ==  newEschol) ? "carried" :
             (Set.new(oldEschol).subset?(Set.new(newEschol))) ? "combined" :
             (Set.new(newEschol).subset?(Set.new(oldEschol))) ? "split" :
                                          "shuffled"

  # See if it's linked to any authors
  authStatus = (info[:rels] || []).empty? ? "unclaimed" : "claimed"
  authHash = Digest::MD5.hexdigest((info[:rels] || []).sort.to_s)

  # See if it's being suggested to any authors
  suggStatus = (info[:suggs] || []).empty? ? "no-sugg" : "sugg"

  pubMain[rtStatus] << pubID
  pubXfer[rtStatus + ":" + authStatus + ":" + suggStatus] << pubID
  schemes.each { |scheme|
    next if scheme =~ /c-|dspace/
    pubScheme[rtStatus + ":" + scheme] << pubID
  }

  # Record some extra data
  (oldEschol || []).each { |ark|
    pubToRT1Ark[pubID] << ark
    rt1ArkToPub[ark] << pubID
  }
  (newEschol || []).each { |ark|
    pubToRT2Ark[pubID] << ark
    rt2ArkToPub[ark] << pubID
  }

  pubToAuth[pubID] = authStatus
  pubToAuthHash[pubID] = authHash
  pubToSugg[pubID] = suggStatus
}

open("arkToPub.txt", "w") { |io|
  rt1ArkToPub.sort.each { |ark, pubs|
    io.puts "#{ark},#{pubs[0]}"
  }
}

pubMain.to_a.sort.each { |k, v|
  puts "size pubMain[#{k}] = #{pubMain[k].size}"
  puts "  #{pubMain[k].sort{|a,b| Zlib::crc32(a) <=> Zlib::crc32(b)}[0..9].join(" ")}"
}
puts

pubXfer.to_a.sort.each { |k, v|
  puts "size pubXfer[#{k}] = #{pubXfer[k].size}"
  puts "  #{pubXfer[k].sort{|a,b| Zlib::crc32(a) <=> Zlib::crc32(b)}[0..9].join(" ")}"
}
puts

pubScheme.to_a.sort.each { |k, v|
  puts "size pubScheme[#{k}] = #{pubScheme[k].size}"
  puts "  #{pubScheme[k].sort{|a,b| Zlib::crc32(a) <=> Zlib::crc32(b)}[0..9].join(" ")}"
}
puts

dropClassCounts = Hash.new { |h,k| h[k] = 0 }

File.open("drop.csv", "w") { |io|
  io.puts("old-pub\tauth?\tsugg?\tark1\tark2\tclass\tnew-pub1\tnew-pub2\tauth\tsugg\tark1\tark2\tother arks")
  todo = Set.new
  pubXfer.to_a.sort.each { |k, v|
    next unless k =~ /dropped:claimed/
    todo += v
  }
  # Put them in random (ish) order by hash, for easy but consistent sampling.
  todo.to_a.sort { |a,b| Zlib::crc32(a) <=> Zlib::crc32(b) }.each { |pubID|
    #puts "Dropped #{pubID}:"
    dropClass = "badway"
    oldExt = anyExtRecords(getInfo(pubID))
    oldArks = (pubToRT1Ark[pubID]||[])
    oldAuth = pubToAuth[pubID]
    oldAuthHash = pubToAuthHash[pubID]
    oldSugg = pubToSugg[pubID]
    oldIncomp = oldArks.map { |ark|
      path = "/apps/eschol/erep/data/13030/pairtree_root/#{ark.scan(/\w\w/).join('/')}/#{ark}"
      File.exist?("#{path}/next/meta/#{ark}.meta.xml") && !File.exist?("#{path}/meta/#{ark}.meta.xml") ? ark : nil
    }.compact
    newPubs = (pubToRT1Ark[pubID]||[]).map{ |ark| rt2ArkToPub[ark] }.compact.flatten.uniq
    newExt = newPubs.any? { |newPub| anyExtRecords(getInfo(newPub)) }
    newAuth = newPubs.map{ |newPub| pubToAuth[newPub] }.compact.uniq.join("/")
    newAuthHash = newPubs.empty? ? nil : pubToAuthHash[newPubs[0]]
    if newAuth == "claimed"
      newAuth = oldAuthHash == newAuthHash ? "claimed same" : "claimed diff"
    end
    newSugg = newPubs.map{ |newPub| pubToSugg[newPub] }.compact.uniq.join("/")
    newArks = newPubs.map{ |newPub| pubToRT2Ark[newPub] }.compact.flatten.uniq
    dropClass = case
      when oldExt && !newExt; oldIncomp == oldArks ? "incomplete" : "bad way"
      when !oldExt && newExt; "good way"
      when oldExt && newExt;  oldAuthHash == newAuthHash ? "wash" : "switch-auth"
      else                    "irrel"
    end
    dropClassCounts[dropClass] += 1
    #oldArks.size <= 2 or raise
    io.print("#{pubURL(pubID, oldExt)}\t#{oldAuth}\t#{oldSugg}\t" +
             "#{arkURL(oldArks[0])}\t#{arkURL(oldArks[1])}\t#{dropClass}\t")
    if newPubs
      newPubs.size <= 2 or raise
      io.puts("#{pubURL(newPubs[0], anyExtRecords(getInfo(newPubs[0])))}\t" +
              "#{pubURL(newPubs[1], anyExtRecords(getInfo(newPubs[1])))}\t" +
              "#{newAuth}\t#{newSugg}\t" +
              "#{newArks==oldArks ? "same" : arkURL(newArks[0])}\t" +
              "#{newArks==oldArks ? "" : arkURL(newArks[1])}\t" +
              "#{newArks==oldArks || newArks.size <= 2 ? "" : newArks[2..-1].join(", ")}")
    else
      io.puts("\t\t")
    end
  }
}

puts "dropClassCounts: #{dropClassCounts}"
