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
$pubInfo = DBM.open("#{$scriptDir}/cache.new/pubInfo", 0644, DBM::WRCREAT)
$oapToPub = DBM.open("#{$scriptDir}/cache.new/oapToPub", 0644, DBM::WRCREAT)
$arkToRT2Pub = DBM.open("#{$scriptDir}/cache.new/arkToRT2Pub", 0644, DBM::WRCREAT)

###################################################################################################
def addID(recordIDs, name, text)
  if !recordIDs.key?(name)
    recordIDs[name] = [text]
  elsif !recordIDs[name].include?(text)
    recordIDs[name] << text
  end
end

###################################################################################################
def fetchAndProcess(url)
  auth = { :username => ENV['ELEMENTS_API_USERNAME'] || raise("missing env ELEMENTS_API_USERNAME"),
           :password => ENV['ELEMENTS_API_PASSWORD'] || raise("missing env ELEMENTS_API_PASSWORD") }

  resp = HTTParty.get(url, :basic_auth => auth)
  return if resp.code == 404   # not found
  return if resp.code == 410   # deleted
  resp.code == 200 or raise("Unexpected error #{resp.code} from Elements API for #{url}: #{resp}")
  data = Nokogiri::XML(resp.body).remove_namespaces!

  pubEl = data.at("object[@category='publication']")
  pubEl or return

  pubID = pubEl['id']
  return if $pubInfo.key?(pubID)

  #puts "    pub #{pubID}"

  recordIDs = {}
  pubEl.xpath("records/record[@format='native']").each { |record|
    addID(recordIDs, record['source-name'], record['id-at-source'])
    record.xpath(".//field").each { |field|
      field['name'] =~ /^c-/ and addID(recordIDs, field['name'], field.at('text').text)
    }
  }

  #puts "    record IDs #{recordIDs.inspect}"

  # Query related users (authors mostly)
  url = "#{$apiHost}/publications/#{pubID}/relationships"
  resp = HTTParty.get(url, :basic_auth => auth)
  resp.code == 200 or raise("Unexpected error #{resp.code} from Elements API for #{url}: #{resp}")
  data = Nokogiri::XML(resp.body).remove_namespaces!

  rels = []
  data.xpath(".//entry").each { |entry|
    relationshipText = entry.at("title").text
    userObj = entry.at("relationship/related/object")
    userObj or raise("can't find related object")
    userID = userObj['id']
    rels << "#{relationshipText} (#{userID})"
  }
  #puts "    rels #{rels}"

  # Query suggestions (pending links to potential authors)
  url = "#{$apiHost}/publications/#{pubID}/suggestions/relationships/pending"
  resp = HTTParty.get(url, :basic_auth => auth)
  resp.code == 200 or raise("Unexpected error #{resp.code} from Elements API for #{url}: #{resp}")
  data = Nokogiri::XML(resp.body).remove_namespaces!

  suggs = []
  data.xpath(".//entry").each { |entry|
    relationshipText = entry.at("title").text
    userObj = entry.at("relationship-suggestion/related/object")
    userObj or raise("can't find related object")
    userID = userObj['id']
    suggs << "#{relationshipText} (#{userID})"
  }
  #puts "    suggs #{suggs}"

  $pubInfo[pubID] = Marshal.dump({ ids: recordIDs, rels: rels, suggs: suggs })
  return pubID
end

###################################################################################################
def buildArkToPub

  # We have multiple sources of data for this. First is the arks database, which is where things
  # synchronously uploaded from Elements end up.
  map = {}
  donePubs = Set.new
  $arkDb.execute("SELECT id, external_id FROM arks WHERE source='elements'") { |row|
    ark, pubID = row
    next if donePubs.include?(pubID)
    next if pubID =~ /\w{8}-\w{4}-\w{4}-\w{4}-\w{12}/
    donePubs << pubID
    ark and ark.sub!('ark:13030/', 'ark:/13030/')
    map[ark] = pubID
  }

  # Second source is the oap database, which is where we record items that pre-existed Elements
  # and have been imported by our OAP importer.
  $oapDb.execute("SELECT campus_id, pub_id FROM ids, pubs WHERE ids.oap_id = pubs.oap_id " +
                 "AND campus_id LIKE 'c-eschol-id::%'") { |row|
    ark, pubID = row
    next if donePubs.include?(pubID)
    donePubs << pubID
    ark and ark.sub!('c-eschol-id::', '')
    ark and ark.sub!('ark:13030/', 'ark:/13030/')
    map[ark] = pubID
  }

  # Third source is the eschol_equiv table (also houses in oap database), which is where we
  # items go when the user specifies an escholarship URL as the OA URL for a pub. (Also, this
  # table contains items auto-batch-imported to eSchol based on an Elements record).
  $oapDb.execute("SELECT pub_id, eschol_ark FROM eschol_equiv") { |row|
    pubID, ark = row
    next if donePubs.include?(pubID)
    donePubs << pubID
    ark =~ %r{^ark:/13030} or raise("strange ark #{ark.inspect} in eschol_equiv table")
    map[ark] or map[ark] = pubID
  }

  return map
end

###################################################################################################
def scanPubs
  # Build a mapping of arks to pubs
  puts "Building arkToPub"
  arkToPub = buildArkToPub

  # Scan each of those pubs.
  arkToPub.values.sort.each.with_index { |pub, idx|
    ((idx % 100) == 1) and puts "Processing pub #{idx} of #{arkToPub.size}."
    next if $pubInfo.key?(pub)
    next if pub.include?("merged:")
    fetchAndProcess("#{$apiHost}/publications/#{pub}")
  }
  puts "Done processing pubs."
end

###################################################################################################
def scanOAPs

  # Locate each OAP pub attached to an eschol record
  puts "Collecting OAP IDs."
  oapIDs = Set.new($oapDb.execute('select oap_id from ids where campus_id like \'%eschol%\'').map { |row| row[0] })

  # Cancel those we've already processed earlier.
  $pubInfo.each { |pubID, idStr|
    ids = Marshal.load(idStr)
    instId = ids['c-inst-1']
    instId and $oapToPub[instId] = pubID
  }
  puts "Canceled #{$oapToPub.size}"

  # Now query each OAP id and see what's what
  puts "Querying each OAP in Elements."
  oapIDs.to_a.sort.each.with_index { |oapID, idx|
    ((idx % 100) == 1) and puts "Processing OAP #{idx} of #{oapIDs.size}."

    next if $oapToPub.key?(oapID)

    #puts "  OAP #{oapID}"

    pubID = fetchAndProcess("#{$apiHost}/publication/records/c-inst-1/#{CGI.escape(oapID)}")
    $oapToPub[oapID] = pubID
  }
  puts "Done querying OAPs."
end

###################################################################################################
def scanARKs

  # Cancel eschol arks that we've already seen on RT2
  rt2ArksDone = Set.new($pubInfo.map { |pubID, idStr|
    Marshal.load(idStr)['dspace'] =~ /(qt\w{8})/; $1
  }.compact)

  puts "Canceled #{rt2ArksDone.size} arks."

  $arkToRT2Pub.keys.each { |ark| rt2ArksDone << ark }

  puts "Total cancel #{rt2ArksDone.size} arks."

  allArks = $arkDb.execute("SELECT id FROM arks ORDER BY id").map { |row|
    row[0] =~ /(qt\w{8})/ or raise("can't parse long ark"); $1
  }.compact

  allArks.each.with_index { |ark, idx|
    ((idx % 100) == 1) and puts "Processing ARK #{idx} of #{allArks.size}."
    next if rt2ArksDone.include?(ark)
    $arkToRT2Pub[ark] = fetchAndProcess("#{$apiHost}/publication/records/dspace/#{ark}")
  }
end

###################################################################################################
# The main routine

scanPubs
scanOAPs
scanARKs

puts "Done."
