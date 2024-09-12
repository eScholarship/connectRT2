# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'cgi'
require 'digest'
require 'erubis'
require 'fileutils'
require 'json-diff'
require 'securerandom'
require 'unindent'
require 'uri'
require 'xmlsimple'

require "#{$espylib}/ark.rb"     # for normalizeArk
require "#{$espylib}/xmlutil.rb" # for text_at

require_relative './transform.rb'

$jscholKey = ENV['JSCHOL_KEY'] or raise("missing env JSCHOL_KEY")

$sessions = {}
MAX_SESSIONS = 5

$userErrors = {}
MAX_USER_ERRORS = 40

$recentArkInfo = {}
MAX_RECENT_ARK_INFO = 20

$recentGuids = []
MAX_RECENT_GUIDS = 40

$nextMoreToken = {}
MAX_NEXT_MORE_TOKEN = 20

$privApiKey = ENV['ESCHOL_PRIV_API_KEY'] or raise("missing env ESCHOL_PRIV_API_KEY")

$rt2Email = ENV['RT2_DSPACE_EMAIL'] or raise("missing env RT2_DSPACE_EMAIL")
$rt2Password = ENV['RT2_DSPACE_PASSWORD'] or raise("missing env RT2_DSPACE_PASSWORD")

$feedTmpDir = "#{$homeDir}/apache/htdocs/bitstreamTmp"

###################################################################################################
ITEM_META_FIELDS = %{
  id
  title
  authors(first:500) {
    nodes {
      email
      orcid
      nameParts {
        fname
        mname
        lname
        suffix
        institution
        organization
      }
    }
  }
  contributors(first:500) {
    nodes {
      role
      email
      nameParts {
        fname
        mname
        lname
        suffix
        institution
        organization
      }
    }
  }
  localIDs {
    id
    scheme
    subScheme
  }
  units {
    id
    name
    parents {
      name
    }
    items {
      total
    }
  }
  abstract
  added
  bookTitle
  disciplines
  embargoExpires
  pagination
  isPeerReviewed
  fpage
  lpage
  grants
  issn
  isbn
  journal
  issue
  volume
  keywords
  publisher
  published
  language
  permalink
  proceedings
  published
  rights
  source
  status
  subjects
  title
  type
  ucpmsPubType
  updated
}

ITEM_FILE_FIELDS = %{
  contentLink
  contentType
  contentSize
  externalLinks
  nativeFileName
  nativeFileSize
  suppFiles {
    file
    size
    contentType
  }
}

###################################################################################################
# Nice way to generate XML, just using ERB-like templates instead of Builder's weird syntax.
def xmlGen(templateStr, bnding, xml_header: true)
  $templates ||= {}
  template = ($templates[templateStr] ||= XMLGen.new(templateStr))
  doc = Nokogiri::XML(template.result(bnding), nil, "UTF-8", &:noblanks)
  return xml_header ? doc.to_xml : doc.root.to_xml
end
class XMLGen < Erubis::Eruby
  include Erubis::EscapeEnhancer
end

#################################################################################################
# Send a GraphQL query to the eschol access API, returning the JSON results.
def accessAPIQuery(query, vars = {}, privileged = false)
  if vars.empty?
    query = "query { #{query} }"
  else
    query = "query(#{vars.map{|name, pair| "$#{name}: #{pair[0]}"}.join(", ")}) { #{query} }"
  end
  varHash = Hash[vars.map{|name,pair| [name.to_s, pair[1]]}]
  headers = { 'Content-Type' => 'application/json' }
  privileged and headers['Privileged'] = $privApiKey
  ENV['ESCHOL_ACCESS_COOKIE'] and headers['Cookie'] = "ACCESS_COOKIE=#{ENV['ESCHOL_ACCESS_COOKIE']}"

  # Send the HTTP request to the graphQL endpoint
  begin
    retries ||= 0
    response = HTTParty.post("#{$escholServer}/graphql",
                 :headers => headers,
                 :body => { variables: varHash, query: query }.to_json)
    if response.code != 200
      raise("Internal error (graphql): HTTP code #{response.code} - #{response.message}.\n" + "#{response.body}")
    end
  rescue Exception => exc
    if (response && [500,502,504].include?(response.code) && response.body.length < 200) ||
       (exc.to_s =~ /execution expired|Failed to open TCP connection|Connection reset by peer|ReadTimeout|SSL_connect/i)
      retries += 1
      if retries <= 10
        puts "Empty code 500 response or exception: #{exc.to_s.inspect}. Will retry."
        sleep 5
        retry
      end
    end
    raise

  end


  if response['errors']
    puts "Full error text:"
    pp response['errors']
    raise("Internal error (graphql): #{response['errors'][0]['message']}")
  end

  return response['data']
end

#################################################################################################
# Send a mutation to the submission API, returning the JSON results.
def submitAPIMutation(mutation, vars)
  query = "mutation(#{vars.map{|name, pair| "$#{name}: #{pair[0]}"}.join(", ")}) { #{mutation} }"
  varHash = Hash[vars.map{|name,pair| [name.to_s, pair[1]]}]
  headers = { 'Content-Type' => 'application/json' }
  headers['Privileged'] = $privApiKey
  ENV['ESCHOL_ACCESS_COOKIE'] and headers['Cookie'] = "ACCESS_COOKIE=#{ENV['ESCHOL_ACCESS_COOKIE']}"
  response = HTTParty.post("#{$escholServer}/graphql",
               :headers => headers,
               :body => { variables: varHash, query: query }.to_json)
  response.code != 200 and raise("Internal error (graphql): " +
     "HTTP code #{response.code} - #{response.message}.\n" +
     "#{response.body}")
  if response['errors']
    puts "Full error text:"
    pp response['errors']
    raise("Internal error (graphql): #{response['errors'][0]['message']}")
  end
  return response['data']
end

###################################################################################################
def getSession
  if request.env['HTTP_COOKIE'] =~ /JSESSIONID=(\w{32})/
    session = $1
    if $sessions.include?(session)
      #puts "Got existing session: #{session}"
      return session
    end
  end

  session = SecureRandom.hex(16).upcase
  $sessions.size >= MAX_SESSIONS and $sessions.shift
  $sessions[session] = { time: Time.now, loggedIn: false }
  headers 'Set-Cookie' => "JSESSIONID=#{session}; Path=/dspace-rest"
  #puts "Created new session: #{session}"
  return session
end

###################################################################################################
# We only allow Elements to overwrite certain types of eSchol items.
def checkOverwriteOK(shortArk)
  data = accessAPIQuery("item(id: $itemID) { source units{ id } }",
    { itemID: ["ID!", "ark:/13030/#{shortArk}"] }).dig("item")

  # New items are definitely ok
  data or return

  # Fine for Elements to overwrite its own items
  data['source'] == 'oa_harvester' and return

  # Things that didn't come from Subi or bepress (such as springer or ETDs) can't be considered
  # campus postprints. So they can't be modified.
  data['source'] == 'ojs' and userErrorHalt(shortArk, "Cannot modify items from eScholarship-hosted journals.")
  data['source'] =~ /^(subi|repo)$/ or userErrorHalt(shortArk, "Cannot modify items imported from external systems.")

  # Campus postprints are ok
  if data['units'].all? { |unitID| unitID =~ /^uc\w\w?$/ }
    return
  else
    userErrorHalt(shortArk, """
      This item is part of a departmental collection <br/>
      on eScholarship and cannot be modified here. <br/>
      For more information visit the
      <a target='_blank' href='https://help.oapolicy.universityofcalifornia.edu'>Help Center</a>.
    """.unindent)
  end
end

###################################################################################################
def clearItemFiles(ark)
  if (info = $recentArkInfo[ark])
    # Delete all the old files regardless of whether we succeeded or failed.
    info[:files].each { |path| File.unlink(path) }

    # Clear old data so it can be re-done if needed
    info[:meta] = { id: "ark:/13030/#{ark}" }
    info[:files] = []
    $recentArkInfo.delete(ark)
  end
end

###################################################################################################
def approveItem(ark, info, replaceOnly: nil)
  ark =~ /^qt\w{8}$/ or raise("invalid ark")
  info && info[:meta] or raise("missing data")

  # We don't allow editing of non-campus postprints, among other things.
  checkOverwriteOK(ark)

  # Now run the right API mutation
  begin
    if replaceOnly == :files
      puts "Replacing files for item #{ark}."
      submitAPIMutation("replaceFiles(input: $input) { message }", { input: ["ReplaceFilesInput!", info[:meta]] })
    elsif replaceOnly == :metadata
      puts "Replacing metadata for item #{ark}."
      submitAPIMutation("replaceMetadata(input: $input) { message }", { input: ["ReplaceMetadataInput!", info[:meta]] })
    else
      puts "Depositing item #{ark}."
      outID = submitAPIMutation("depositItem(input: $input) { id }",
                                { input: ["DepositItemInput!", info[:meta]] }).dig("depositItem", "id")
      outID.include?(ark) or raise("depositItem didn't work right")
    end
  ensure
    clearItemFiles(ark)
  end
end

###################################################################################################
get "/dspace-rest/status" do
  content_type "text/xml"
  if $sessions[getSession][:loggedIn]
    xmlGen('''
      <status>
        <authenticated>true</authenticated>
        <email><%=email%></email>
        <fullname>DSpace user</fullname>
        <okay>true</okay>
      </status>''', {email: $rt2email})
  else
    xmlGen('''
      <status>
        <apiVersion>6.3</apiVersion>
        <authenticated>false</authenticated>
        <okay>true</okay>
        <sourceVersion>6.3</sourceVersion>
      </status>''', {})
  end
end

###################################################################################################
post "/dspace-rest/login" do
  content_type "text/plain;charset=utf-8"
  params['email'] == $rt2Email && params['password'] == $rt2Password or halt(401, "Unauthorized.\n")
  $sessions[getSession][:loggedIn] = true
  #puts "==> Login ok, setting flag on session."
  "OK\n"
end

###################################################################################################
def verifyLoggedIn
  #puts "Verifying login, cookie=#{request.env['HTTP_COOKIE']}"
  $sessions[getSession][:loggedIn] or halt(401, "Unauthorized.\n")
end

###################################################################################################
def genCollectionData(unitID)
  data = accessAPIQuery("unit(id: $unitID) { items { total } }", { unitID: ["ID!", unitID] }).dig("unit")
  xmlGen('''
    <collection>
      <link>/rest/collections/13030/<%= unitID %></link>
      <expand>parentCommunityList</expand>
      <expand>parentCommunity</expand>
      <expand>items</expand>
      <expand>license</expand>
      <expand>logo</expand>
      <expand>all</expand>
      <handle>13030/<%= unitID %></handle>
      <name><%= unitID %></name>
      <type>collection</type>
      <UUID><%= unitID %></UUID>
      <copyrightText/>
      <introductoryText/>
      <numberItems><%= data.dig("items", "total") %></numberItems>
      <shortDescription><%= unitID %></shortDescription>
      <sidebarText/>
    </collection>''', binding, xml_header: false)
end

###################################################################################################
post "/dspace-rest/collections/find-collection" do
  verifyLoggedIn
  content_type "text/xml"
  request.body.rewind
  unitID = request.body.read.strip
  unitID =~ /^[\w_]+$/ or raise("unable to parse find-collection id #{unitID.inspect}")
  genCollectionData(unitID)
end

###################################################################################################
get "/dspace-rest/collections" do
  verifyLoggedIn
  content_type "text/xml"
  inner = %w{cdl_rw iis_general root}.map { |unitID| genCollectionData(unitID) }
  xmlGen('''
    <collections>
      <%== inner.join("\n") %>
    </collections>
  ''', binding)
end

###################################################################################################
def stripHTML(encoded)
  encoded.gsub("&amp;lt;", "&lt;").gsub("&amp;gt;", "&gt;").gsub(%r{&lt;/?\w+?&gt;}, "")
end

###################################################################################################
def calcContentReadKey(itemID, contentPath)
  key = Digest::SHA1.hexdigest($jscholKey + "|read|" + contentPath).to_i(16).to_s(36)
end

###################################################################################################
def filePreviewLink(itemID, contentPath)
  server = "https://#{request.host}"
  key = calcContentReadKey(itemID, contentPath)
  return "#{server}/dspace-preview/#{itemID}/#{contentPath}?key=#{key}"
end

###################################################################################################
def formatItemData(data, expand)
  data.delete_if{ |k,v| v.nil? || (v.respond_to?(:empty) && v.empty?) }
  itemID = data['id'] or raise("expected to get item ID")
  itemID.sub!("ark:/13030/", "")

  if expand =~ /metadata/
    fullData = data.clone

    # In order to facilitate mimicing the DSapce output, we nest the metadata inside of a "root" node
    metaXML = stripHTML(XmlSimple.xml_out(fullData, {suppress_empty: nil, noattr: true, rootname: "root"}))
    metaXML.sub!("<metadata>", "<metadata><key>eschol-meta-update</key><value>true</value>")

    metaXML = mimicDspaceXMLOutput(metaXML)

  else
    metaXML = ""
  end
  lastMod = Time.parse(data.dig("updated")).strftime("%Y-%m-%d %H:%M:%S")

  if expand =~ /parentCollection/
    collections = (data['units'] || []).map { |unit|
      parentName = unit.dig("parents", 0, "name")
      fullUnitName = parentName ? "#{parentName}: #{unit["name"]}" : unit["name"]
      xmlGen('''
        <parentCollection>
          <link>/rest/collections/13030/<%= unit["id"] %></link>
          <expand>parentCommunityList</expand>
          <expand>parentCommunity</expand>
          <expand>items</expand>
          <expand>license</expand>
          <expand>logo</expand>
          <expand>all</expand>
          <handle>13030/<%= unit["id"] %></handle>
          <name><%= fullUnitName %></name>
          <type>collection</type>
          <UUID><%= unit["id"] %></UUID>
          <copyrightText/>
          <introductoryText/>
          <numberItems><%= unit.dig("items", "total") %></numberItems>
          <shortDescription><%= unit["id"] %></shortDescription>
          <sidebarText/>
        </parentCollection>''', binding, xml_header: false)
    }.join("\n")
  else
    collections = ""
  end

  if expand =~ /bitstreams/
    arr = []
    if data['nativeFileName']
      arr << { id: "#{itemID}/content/#{data['nativeFileName']}",
               name: data['nativeFileName'], size: data['nativeFileSize'],
               link: filePreviewLink(itemID, "content/#{CGI.escape(data['nativeFileName'])}"),
               type: data['contentType'] }
    elsif data['contentLink'] && data['contentType'] == "application/pdf"
      arr << { id: "#{itemID}/content/#{itemID}.pdf",
               name: "#{itemID}.pdf", size: data['contentSize'],
               link: filePreviewLink(itemID, "content/#{itemID}.pdf"),
               type: data['contentType'] }
    end
    (data['suppFiles'] || []).each { |supp|
        arr << { id: "#{itemID}/content/supp/#{CGI.escape(supp['file'])}",
                 name: supp['file'], size: supp['size'],
                 link: filePreviewLink(itemID, "content/supp/#{CGI.escape(supp['file'])}"),
                 type: supp['contentType'] }
    }
    bitstreams = arr.map.with_index { |info, idx|
      # Yes, it's wierd, but DSpace generates one <bitstreams> (plural) element for each bitstream.
      # Maybe somebody would have noticed this if they had bothered documenting their API.
      xmlGen('''
        <bitstreams>
          <link><%= info[:link] %></link>
          <expand>parent</expand>
          <expand>policies</expand>
          <expand>all</expand>
          <name><%= info[:name] %></name>
          <type>bitstream</type>
          <UUID><%= info[:id] %></UUID>
          <bundleName>ORIGINAL</bundleName>
          <description>File</description>
          <format>File</format>
          <mimeType><%= info[:type] %></mimeType>
          <retrieveLink><%= info[:link] %></retrieveLink>
          <sequenceId><%= idx+1 %></sequenceId>
          <sizeBytes><%= info[:size] %></sizeBytes>
        </bitstreams>''', binding, xml_header: false)
    }.join("\n")
  end

  return xmlGen('''
    <item>
      <link>/rest/items/13030/<%= itemID %></link>
      <expand>parentCommunityList</expand>
      <expand>all</expand>
      <handle>13030/<%= itemID %></handle>
      <name><%= data["title"] %></name>
      <type>item</type>
      <UUID><%= itemID %></UUID>
      <archived>true</archived>
      <%== metaXML %>
      <lastModified><%= lastMod %></lastModified>
      <%== collections %>
      <%== collections.gsub("parentCollection", "parentCollectionList") %>
      <withdrawn><%= data.dig("status") == "WITHDRAWN" %></withdrawn>
      <%== bitstreams %>
    </item>''', binding, xml_header: false)

end

###################################################################################################
get %r{/dspace-rest/(items|handle)/(.*)} do
  verifyLoggedIn
  request.path =~ /(qt\w{8})/ or halt(404, "Invalid item ID")
  itemID = $1

  # If this get is on an item that was recently being deposited (or redeposited), this is our
  # one and only signal that the depositing is done.
  if $recentArkInfo.key?(itemID)
    approveItem(itemID, $recentArkInfo[itemID], replaceOnly: :files)
    $recentArkInfo.key?(itemID) and raise("failed to remove recentArkInfo after approve")
  end

  content_type "text/xml"
  data = accessAPIQuery("item(id: $itemID) { #{ITEM_META_FIELDS} #{ITEM_FILE_FIELDS} }",
                        { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item")
  data or halt(404)
  return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + formatItemData(data, params['expand'])
end

###################################################################################################
get %r{/dspace-rest/collections/([^/]+)/items} do |collection|
  verifyLoggedIn

  collection =~ /^(cdl_rw|iis_general|root)$/ or halt(404, "Invalid collection")

  offset = (params['offset'] || 0).to_i

  limit  = (params['limit'] || 10).to_i
  limit >= 1 && limit <= 100 or halt(401, "Limit out of range")

  if offset > 0
    moreToken = $nextMoreToken["#{collection}:#{offset}"]
    doQuery = !moreToken.nil?
  else
    moreToken = nil
    doQuery = true
  end

  if doQuery
    data = accessAPIQuery("""
      unit(id: $collection) {
        items(first: $limit, include: [EMBARGOED,WITHDRAWN,EMPTY,PUBLISHED], more: $more) {
          more
          nodes {
            #{ITEM_META_FIELDS} #{ITEM_FILE_FIELDS}
          }
        }
      }""",
      { collection: ["ID!", collection],
        limit: ["Int", limit],
        more: ["String", moreToken]
      }, true)
  else
    data = {}
  end

  $nextMoreToken.size >= MAX_NEXT_MORE_TOKEN and $nextMoreToken.shift
  $nextMoreToken["#{collection}:#{offset+limit}"] = data.dig("unit", "items", "more")

  formatted = (data.dig("unit", "items", "nodes") || []).map { |itemData|
    formatItemData(itemData, params['expand'])
  }

  content_type "text/xml"
  return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
         "<items>" +
         formatted.join("\n") +
         "</items>"
end

###################################################################################################
def errHalt(httpCode, message)
  puts "Error #{httpCode}: #{message}"
  halt httpCode, message
end

###################################################################################################
post "/dspace-swordv2/collection/13030/:collection" do |collection|

  # POST /dspace-swordv2/collection/13030/cdl_rw
  # with data <entry xmlns="http://www.w3.org/2005/Atom">
  #              <title>From Elements (0be0869c-6f32-48eb-b153-3f980b217b26)</title></entry>
  #              ...

  # Parse the body as XML, and locate the <entry>
  request.body.rewind
  body = Nokogiri::XML(request.body.read).remove_namespaces!
  entry = body.xpath("entry") or errHalt(400, "can't locate <entry> in request: #{body}")

  # Grab the Elements GUID for this publication
  title = (entry.xpath("title") or raise("can't locate <title> in entry: #{body}")).text
  guid = title[/\b\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\b/] or errHalt(400, "can't find guid in title #{title.inspect}")

  # Omitting the "in-progress" header would imply that we should commit this item now, but we have
  # no metadata so that would not be reasonable.
  request.env['HTTP_IN_PROGRESS'] == 'true' or errHalt(400, "can't finalize item without any metadata")

  # Checks for the duplicate new-item post problem
  if $recentGuids.include? guid
    userErrorHalt(nil, "We're experiencing a processing delay: Your deposit may take a few minutes to show up in Elements. Please refresh your publication page in a few minutes.")
  else
    $recentGuids.size >= MAX_RECENT_GUIDS and $recentGUIDs.shift
    $recentGuids << guid
  end

  # Make a provisional eschol ARK for this pub
  ark = submitAPIMutation("mintProvisionalID(input: $input) { id }", { input: ["MintProvisionalIDInput!",
    { sourceName: "elements", sourceID: guid }] }).dig("mintProvisionalID", "id")
  ark =~ %r<^ark:/?13030/qt\w{8}$> or raise("bad result #{ark.inspect} from mintProvisionalID")

  # Return a customized XML response.
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  [201, xmlGen('''
    <entry xmlns="http://www.w3.org/2005/Atom">
      <content src="<%=$submitServer%>/swordv2/edit-media/<%=ark%>" type="application/zip"/>
      <link href="<%=$submitServer%>/swordv2/edit-media/<%=ark%>"rel="edit-media" type="application/zip"/>
      <title xmlns="http://purl.org/dc/terms/"><%=title%></title>
      <title type="text"><%=title%></title>
      <rights type="text"/>
      <updated><%=DateTime.now.iso8601%></updated>
      <generator uri="http://escholarship.org/ns/dspace-sword/1.0/" version="1.0">help@escholarship.org</generator>
      <id><%=$submitServer%>/swordv2/edit/<%=ark%></id>
      <link href="<%=$submitServer%>/swordv2/edit/<%=ark%>" rel="edit"/>
      <link href="<%=$submitServer%>/swordv2/edit/<%=ark%>"rel="http://purl.org/net/sword/terms/add"/>
      <link href="<%=$submitServer%>/swordv2/edit-media/<%=ark%>.atom" rel="edit-media"
            type="application/atom+xml; type=feed"/>
      <packaging xmlns="http://purl.org/net/sword/terms/">http://purl.org/net/sword/package/SimpleZip</packaging>
      <treatment xmlns="http://purl.org/net/sword/terms/">A metadata only item has been created</treatment>
    </entry>''', binding, xml_header: false)]
end

###################################################################################################
def retryMetaUpdate(qtArks)
  qtArks.each do |itemID|
    itemStartTime = Time.now

    # Find out the update time of this item in eScholarship
    itemQuery = %{ item(id: $itemID) { updated } }
    data = accessAPIQuery(itemQuery, { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item") or halt(404)
    updatedInEschol = Time.parse(data['updated'])
    oldFeed = "#{$scriptDir}/failedUpdates/#{itemID}.feed.xml"
    updatedInFile = File.mtime(oldFeed)

    if updatedInFile < updatedInEschol
      puts "Update is out-of-date (file=#{updatedInFile} eschol=#{updatedInEschol})... skipping."
      outdatedLoc = "#{$scriptDir}/outdatedFailedUpdates/#{itemID}.feed.xml"
      FileUtils.mkdir_p(File.dirname(outdatedLoc))
      File.rename(oldFeed, outdatedLoc)
      next
    end

    # Locate the old feed, and put it back in the temp dir for the retry
    puts "Processing feed #{oldFeed}."
    File.exist?(oldFeed) or raise("Can't find #{oldFeed}")
    feedFile = "feed__#{SecureRandom.hex(20)}.xml"
    feedPath = "#{$feedTmpDir}/#{feedFile}"
    FileUtils.cp(oldFeed, feedPath)

    # Read the feed and get it back into a hash
    rawData = File.open(oldFeed, "r:UTF-8", &:read)
    feedXML = Nokogiri::XML(rawData, nil, "UTF-8", &:noblanks).remove_namespaces!
    metaHash = parseMetadataEntries(feedXML)

    # And retry the update
    processMetaUpdate(nil, itemID, metaHash, feedFile)

    # Done. Clear the old file.
    fixedLoc = "#{$scriptDir}/fixedUpdates/#{itemID}.feed.xml"
    FileUtils.mkdir_p(File.dirname(fixedLoc))
    puts "Retry successful; moving to #{fixedLoc}."
    File.rename(oldFeed, fixedLoc)

    # Limit the rate of these to 2 per minute.
    toSleep = 30 - (Time.now - itemStartTime).floor
    if toSleep > 0
      puts "Pausing #{toSleep} sec to limit rate."
      sleep toSleep
    end
  end
end

###################################################################################################
def retryHolidayUpdate(qtArks)
  qtArks.each do |itemID|

    # Find out the update time of this item in eScholarship
    itemQuery = %{ item(id: $itemID) { updated } }
    data = accessAPIQuery(itemQuery, { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item") or halt(404)
    updatedInEschol = Time.parse(data['updated'])
    oldFeed = "#{$scriptDir}/holidayUpdates/#{itemID}.feed.xml"
    updatedInFile = File.mtime(oldFeed)

    if updatedInFile < updatedInEschol
      puts "Update is out-of-date (file=#{updatedInFile} eschol=#{updatedInEschol})... skipping."
      outdatedLoc = "#{$scriptDir}/outdatedHolidayUpdates/#{itemID}.feed.xml"
      FileUtils.mkdir_p(File.dirname(outdatedLoc))
      File.rename(oldFeed, outdatedLoc)
      next
    end

    # Locate the old feed, and put it back in the temp dir for the retry
    File.exist?(oldFeed) or raise("Can't find #{oldFeed}")
    feedFile = "feed__#{SecureRandom.hex(20)}.xml"
    feedPath = "#{$feedTmpDir}/#{feedFile}"
    FileUtils.cp(oldFeed, feedPath)

    # Read the feed and get it back into a hash
    rawData = File.open(oldFeed, "r:UTF-8", &:read)
    feedXML = Nokogiri::XML(rawData, nil, "UTF-8", &:noblanks).remove_namespaces!
    metaHash = parseMetadataEntries(feedXML)

    # And retry the update
    processMetaUpdate(nil, itemID, metaHash, feedFile)

    # Done. Clear the old file.
    fixedLoc = "#{$scriptDir}/retriedHolidayUpdates/#{itemID}.feed.xml"
    FileUtils.mkdir_p(File.dirname(fixedLoc))
    puts "Retried; moving to #{fixedLoc}."
    File.rename(oldFeed, fixedLoc)
  end
end

###################################################################################################
def removeNils(struc)
  if struc.is_a?(Hash)
    out = {}
    struc.keys.sort.each { |k|
      if struc[k].is_a?(Hash) && struc[k].size == 1 && struc[k].keys[0] == 'nodes'
        out[k] = removeNils(struc[k].values[0])
      elsif k == 'units' && struc[k].is_a?(Array) && struc[k][0].is_a?(Hash)
        out[k] = struc[k].map { |unitInfo| unitInfo['id'] }
      elsif k == 'grants' && struc[k].is_a?(Array) && struc[k][0].is_a?(Hash)
        out[k] = struc[k].map { |grantInfo| grantInfo['name'] }
      else
        struc[k].nil? or out[k] = removeNils(struc[k])
      end
    }
    return out
  elsif struc.is_a?(Array)
    out = []
    struc.each { |v|
      v.nil? or out << removeNils(v)
    }
    return out
  else
    return struc
  end
end

###################################################################################################
def processMetaUpdate(requestURL, itemID, metaHash, feedFile)

  begin
    if !metaHash.key?('groups')
      puts "...no groups present; skipping update."
      return nil # content length zero, and HTTP 200 OK
    end

    # There are a few pieces of data that don't come with subsequent updates that we need. Get
    # them from the old item. But let's grab everything so we can do a detailed diff.
    itemQuery = %{ item(id: $itemID) { #{ITEM_META_FIELDS} } }
    data = accessAPIQuery(itemQuery, { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item") or halt(404)

    if data['source'] != 'oa_harvester'
      puts "...skipping metadata update of non-Elements item (it's a #{data['source'].inspect} item)"
      return nil # content length zero, and HTTP 200 OK
    end

    pubID = metaHash['elements-pub-id'] or raise("Can't find elements-pub-id in feed")
    pubDate = data['published'] or raise("can't find old pub date")
    who = "elements@escholarship.org"

    puts "Found: pubID=#{pubID.inspect}"

    oldData = {}
    oldData[:units] = (data["units"] || []).map { |unit| unit['id'] }
    metaHash['deposit-date'] = pubDate
    jsonMeta = elementsToJSON(oldData, pubID, who, metaHash, "ark:/13030/#{itemID}", feedFile)
    jsonMeta[:embargoExpires] = data['embargoExpires']
    jsonMeta[:rights] = data['rights']
    #puts "jsonMeta:"; pp jsonMeta

    # We don't generate certain fields on our side; also filter out keywords since they're basically unused.
    d1 = removeNils(JSON.parse(data.to_json))
    %w{added pagination permalink source status updated keywords}.each { |key| d1.delete(key) }

    # Certain fields aren't available via an API query; also filter out keywords since they're basically unused.
    d2 = removeNils(JSON.parse(jsonMeta.to_json))
    %w{pubRelation sourceFeedLink sourceID sourceName submitterEmail keywords}.each { |key| d2.delete(key) }

    # FOR DEBUGGING, you can output the JSONs which are compared and saved to "diff"
    # puts "\nd1="; pp d1
    # puts "\nd2="; pp d2

    diff = JsonDiff.diff(d1, d2, include_was: true)
    puts "Anticipated diff:"; pp diff

    if diff.empty?
      puts "No anticipated diff; skipping update."
      return nil
    elsif diff == []
      puts "Empty diff array; No anticipated diff; skipping update."
      return nil
    end

    approveItem(itemID, { meta: jsonMeta }, replaceOnly: :metadata)

    # FOR DEBUGGING, you can re-query the data to see what diffs there might be
    # DS removed this on 2023-12-13 to speed up the processing queue: It sends
    # an additional GET to eScholarship, practically doubling per-item processing time

    # newData = accessAPIQuery(itemQuery, { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item") or raise
    # diff = JsonDiff.diff(data, newData, include_was: true)
    # diff.reject! { |d| d['path'] == '/updated' }  # not interesting that 'updated' is changing
    # puts "\nFinal metadata diff:"; pp diff

    return nil  # content length zero, and HTTP 200 OK
  rescue Exception => e
    if requestURL
      puts "Exception updating metadata: #{e}"

      # Save the feed; it can later be retried from the command-line
      savePath = "#{$scriptDir}/failedUpdates/#{itemID}.feed.xml"
      FileUtils.mkdir_p(File.dirname(savePath))
      File.rename("#{$feedTmpDir}/#{feedFile}", savePath)

      # And send a notification
      sendErrorEmail(requestURL, "RT2 metadata-update soft failure", e)
      return nil
    else
      raise
    end
  end
end

###################################################################################################
# e.g. PUT /rest/items/qt12345678/metadata
# with data <metadataentries><metadataentry><key>dc.type</key><value>Article</value></metadataentry>
#                            <metadataentry><key>dc.title</key><value>Targeting vivax malaria...
put "/dspace-rest/items/:itemGUID/metadata" do |itemID|
  content_type "text/plain"

  # The ID should be an ARK, obtained earlier from the Sword post.
  itemID =~ /^qt\w{8}$/ or raise("itemID #{itemID.inspect} should be an eschol short ark")

  # The only reason to send this, we think, is to omit the In-Progress header, telling us to
  # publish the item.
  request.env['HTTP_IN_PROGRESS'] != 'true' or errHalt(400, "non-finalizing edit")

  # Grab the body. It should be an XML set of metadata entries.
  request.body.rewind
  body = Nokogiri::XML(request.body.read, nil, "UTF-8", &:noblanks).remove_namespaces!
  #puts "dspaceMetaPut: body=#{body.to_xml}"

  # Store the metadata feed in a URL-accessible place.
  feedFile = "feed__#{SecureRandom.hex(20)}.xml"
  feedPath = "#{$feedTmpDir}/#{feedFile}"
  open(feedPath, "w") { |out| out.write(body.to_xml(indent: 3)) }

  # Parse out the flat list of metadata from the feed into a handy hash
  metaHash = parseMetadataEntries(body)

  # For metadata update, we already have the info we need. Process it and stop.
  if metaHash['eschol-meta-update'] == 'true'
    return processMetaUpdate(request.url, itemID, metaHash, feedFile)
  end

  # For normal deposit, we require a pub ID and depositor
  pubID = metaHash['elements-pub-id'] or raise("Can't find elements-pub-id in feed")
  who = metaHash['depositor-email']
  who =~ URI::MailTo::EMAIL_REGEXP or raise("Can't find valid depositor-email in feed")
  puts "Found pubID=#{pubID.inspect}, who=#{who.inspect}."

  $recentArkInfo.size >= MAX_RECENT_ARK_INFO and $recentArkInfo.shift
  $recentArkInfo[itemID] = { pubID: pubID, who: who }

  # Translate the metadata from Elements' dspace format to eSchol's json format
  jsonMeta = elementsToJSON({}, pubID, who, metaHash, "ark:/13030/#{itemID}", feedFile)
  puts "jsonMeta="; pp jsonMeta

  # And record all of it for the commit which will come later
  $recentArkInfo[itemID][:meta] = jsonMeta
  $recentArkInfo[itemID][:files] = [feedPath]

  # All done.
  nil  # content length zero, and HTTP 200 OK
end

###################################################################################################
def guessMimeType(filePath)
  Rack::Mime.mime_type(File.extname(filePath))
end

###################################################################################################
def isPDF(mimeType)
  return mimeType == "application/pdf"
end

###################################################################################################
def isWordDoc(mimeType)
  return mimeType =~ %r{application/(msword|rtf|vnd.openxmlformats-officedocument.wordprocessingml.document)}
end

###################################################################################################
# e.g. POST /rest/items/qt12345678/bitstreams?name=anvlspec.pdf&description=Accepted%20version
post "/dspace-rest/items/:itemGUID/bitstreams" do |shortArk|
  shortArk =~ /^qt\w{8}$/ or raise("invalid ARK")

  content_type "text/xml"

  fileName = params['name'] or raise("missing 'name' param")
  fileVersion = params['description']

  info = $recentArkInfo[shortArk]
  if !info
    # Re-deposit case
    $recentArkInfo.size >= MAX_RECENT_ARK_INFO and $recentArkInfo.shift
    $recentArkInfo[shortArk] = info = { meta: { id: "ark:/13030/#{shortArk}" }, files: [] }
  end

  # Generate a secure but somewhat meaningful name
  request.body.rewind
  safeName = fileName.gsub(/[^A-Za-z0-9_.]/, '')
  tmpFile = "#{File.basename(safeName,'.*')[0,20]}__#{SecureRandom.hex(20)}#{File.extname(safeName)[0,5]}"

  # Put the file in a URL-accessible place.
  tmpPath = "#{$homeDir}/apache/htdocs/bitstreamTmp/#{tmpFile}"
  open(tmpPath, "w") { |out| FileUtils.copy_stream(request.body, out) }
  size = File.size(tmpPath)
  info[:files] << tmpPath

  # Now stuff it into the metadata
  mimeType = guessMimeType(fileName)
  if fileVersion == "Supporting information" || fileVersion == "Supplemental file"
    # Supplemental file(s)
    info[:meta][:suppFiles] ||= []
    info[:meta][:suppFiles] << { file: fileName, contentType: mimeType, size: size,
                                 fetchLink: "#{$submitServer}/bitstreamTmp/#{tmpFile}" }
  else
    # TK This is the Main file deposit
    # TK : We need to change a function in subiGuts.rb line 255
    #      which  code converts main files PDF.
    #      Afterwords, this the replacement IF statment:
    #
    # if info[:type] == "ARTICLE" &&
    #  (!isPDF(mimeType) && !isWordDoc(mimeType))
    #
    if !isPDF(mimeType) && !isWordDoc(mimeType)
      userErrorHalt(shortArk, "Only PDF and Word docs are acceptable for the main content.")
    end
    if info[:meta][:contentLink]
      userErrorHalt(shortArk, "Only one main file is allowed. \n" +
        "Set the File Version to 'Supporting Information' for supplemental files.")
    end
    info[:meta][:contentLink] = "#{$submitServer}/bitstreamTmp/#{tmpFile}"
    info[:meta][:contentFileName] = fileName
    if fileVersion
      info[:meta][:contentVersion] = case fileVersion
        # Pre-v6.8 terms
        when /(Author's final|Submitted) version/; 'AUTHOR_VERSION'
        when "Published version"; 'PUBLISHER_VERSION'
        # Post-v6.8 terms
        when /(Publisher's|Published) version/; 'PUBLISHER_VERSION'
        when /(Accepted|Submitted) version*/,
             "Author's accepted manuscript";'AUTHOR_VERSION'
        else raise("unrecognized fileVersion #{fileVersion.inspect}")
      end
    end
  end

  xmlGen('''
    <bitstream>
      <link>/rest/bitstreams/<%=shortArk%>/<%=CGI.escape(fileName)%></link>
      <expand>parent</expand>
      <expand>policies</expand>
      <expand>all</expand>
      <name><%=fileName%></name>
      <type>bitstream</type>
      <UUID><%=shortArk%>/<%=CGI.escape(fileName)%></UUID>
      <bundleName>ORIGINAL</bundleName>
      <description><%=fileVersion%></description>
      <mimeType><%=mimeType%></mimeType>
      <retrieveLink>/foo/bar</retrieveLink>
      <sequenceId>-1</sequenceId>
      <sizeBytes><%=size%></sizeBytes>
    </bitstream>''', binding)
end

###################################################################################################
get %r{/dspace-rest/bitstreams/([^/]+)/(.*)/policy} do |itemID, path|
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  itemData = accessAPIQuery("item(id: $itemID) { status embargoExpires }",
               { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item")
  itemData or errHalt(404, "item #{itemID} not found")
  policyGroup = (itemData['status'] =~ /PUBLISHED|EMBARGOED/) ? 0 : 9
  descrip = case itemData['status']
    when 'EMBARGOED'; "EMBARGOED until #{itemData['embargoExpires']}"
    else itemData['status']
  end
  startDateEl = (itemData['status'] == 'EMBARGOED') ?
    "<startDate>#{itemData['embargoExpires']}T00:00:00-0700</startDate>" : nil
  [200, xmlGen('''
    <resourcePolicies>
      <resourcepolicy>
        <action>READ</action>
        <groupId><%= policyGroup %></groupId>
        <id><%= policyGroup+32 %></id>
        <resourceId><%= itemID+"/"+path %>/</resourceId>
        <resourceType>bitstream</resourceType>
        <rpDescription><%= descrip %></rpDescription>
        <%== startDateEl %>
        <rpType>TYPE_INHERITED</rpType>
      </resourcepolicy>
    </resourcePolicies>''', binding)]
end

###################################################################################################
delete "/dspace-rest/bitstreams/:itemID/:filename/policy/:policyID" do |itemID, filename, policyID|
  # Return a fake response.
  [204, "Deleted."]
end

###################################################################################################
post "/dspace-swordv2/edit/:itemID" do |itemID|
  # POST /dspace-swordv2/edit/4463d757-868a-42e2-9aab-edc560089ca1

  itemID =~ /^qt\w{8}$/ or raise("itemID #{itemID.inspect} should be an eschol short ark")

  # The only reason to send this, we think, is to omit the In-Progress header, telling us to
  # publish the item.
  request.env['HTTP_IN_PROGRESS'] != 'true' or errHalt(400, "non-finalizing edit")

  request.body.rewind
  request.body.read.strip == "" or errHalt(400, "don't know what to do with actual edit data")

  # Time to publish this thing.
  info = $recentArkInfo[itemID] or errHalt(400, "data has expired")
  approveItem(itemID, info)

  # Elements doesn't seem to care what we return, as long as it's XML. Hmm.
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  [200, xmlGen('''<entry xmlns="http://www.w3.org/2005/Atom" />''', binding, xml_header: false)]
end

###################################################################################################
get "/dspace-oai" do
  if params['verb'] == 'ListSets'
    content_type "text/xml"
    xmlGen('''
      <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xsi:schemaLocation="http://www.openarchives.org/OAI/2.0/
               http://www.openarchives.org/OAI/2.0/OAI-PMH.xsd">
        <responseDate>2002-08-11T07:21:33Z</responseDate>
        <request verb="ListSets">http://an.oa.org/OAI-script</request>
        <ListSets>
          <set>
            <setSpec>cdl_rw</setSpec>
            <setName>cdl_rw</setName>
          </set>
          <set>
            <setSpec>iis_general</setSpec>
            <setName>iis_general</setName>
          </set>
          <set>
            <setSpec>root</setSpec>
            <setName>root</setName>
          </set>
        </ListSets>
      </OAI-PMH>''', binding)
  else
    # Proxy the OAI query over to the eschol API server, and return its results
    headers = { 'Privileged' => $privApiKey }
    ENV['ESCHOL_ACCESS_COOKIE'] and headers['Cookie'] = "ACCESS_COOKIE=#{ENV['ESCHOL_ACCESS_COOKIE']}"
    response = HTTParty.get("#{$escholServer}/oai", query: params, headers: headers)
    content_type response.headers['Content-Type']
    return [response.code, response.body]
  end
end

###################################################################################################
def arkToPubID(ark)
  # First, try recent ark info
  pubID = ($recentArkInfo[getShortArk(ark)] || {})[:pubID]

  # Failing that, try the eschol5 API
  if !pubID
    data = accessAPIQuery("item(id: $itemID) { localIDs { id scheme } }",
                          { itemID: ["ID!", "ark:/13030/#{getShortArk(ark)}"] })['item']
    if data && data['localIDs']
      found = data['localIDs'].select{ |lid| lid['scheme'] == "OA_PUB_ID" }[0]
      found and pubID = found['id']
    end
  end

  # Last chance, try the Elements API
  if !pubID
    elementsApiHost = ENV['ELEMENTS_API_URL'] || raise("missing env ELEMENTS_API_URL")
    resp = HTTParty.get("#{elementsApiHost}/publication/records/dspace/#{getShortArk(ark)}", :basic_auth =>
      { :username => ENV['ELEMENTS_API_USERNAME'] || raise("missing env ELEMENTS_API_USERNAME"),
        :password => ENV['ELEMENTS_API_PASSWORD'] || raise("missing env ELEMENTS_API_PASSWORD") })
    if resp.code == 200
      data = Nokogiri::XML(resp.body).remove_namespaces!
      pubID = data.xpath("//object[@category='publication']").map{ |r| r['id'] }.compact[0]
    end
  end

  # That's it.
  return pubID
end

###################################################################################################
def userErrorHalt(ark, msg)
  puts "Recording user error #{msg.inspect} for ark #{ark.inspect}."

  # Find the pub corresponding to this ARK
  pubID = arkToPubID(ark)
  if pubID
    puts "Found pubID=#{pubID.inspect}"
    $userErrors.size >= MAX_USER_ERRORS and $userErrors.shift
    $userErrors[pubID] = { time: Time.now, msg: msg }
  else
    puts "Hmm, couldn't find a pub_id"
  end
  clearItemFiles(ark)
  errHalt(400, msg)
end

###################################################################################################
get "/dspace-userErrorMsg/:pubID" do |pubID|
  # CORS support
  origin = request.env['HTTP_ORIGIN']
  origin =~ /oapolicy.universityofcalifornia.edu/ and headers 'Access-Control-Allow-Origin' => origin

  # See if we have a pending message associated with this pub ID
  entry = $userErrors.delete(pubID)
  entry and return entry[:msg]

  # Huh. Oh well, maybe it wasn't a user error but an internal error instead.
  errHalt(404, "Unknown pub")
end

###################################################################################################
get %r{/dspace-preview/(.*)} do |path|
  path =~ %r{^(qt\w{8})/(content/.*)} or halt(400)
  itemID, contentPath = $1, $2
  CGI.unescape(contentPath).include?('..') and halt(400)
  calcContentReadKey(itemID, contentPath) == params['key'] or halt(403)
  fullPath = arkToFile(itemID, CGI.unescape(contentPath))
  send_file(fullPath)
end
