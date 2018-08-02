# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'digest'
require 'erubis'
require 'securerandom'
require 'xmlsimple'

$rt2creds = JSON.parse(File.read("#{$homeDir}/.passwords/rt2_adapter_creds.json"))

$sessions = {}
MAX_SESSIONS = 5

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
# Send a GraphQL query to the eschol API, returning the JSON results.
def apiQuery(query, vars = {}, privileged = false)
  if vars.empty?
    query = "query { #{query} }"
  else
    query = "query(#{vars.map{|name, pair| "$#{name}: #{pair[0]}"}.join(", ")}) { #{query} }"
  end
  varHash = Hash[vars.map{|name,pair| [name.to_s, pair[1]]}]
  headers = { 'Content-Type' => 'application/json' }
  privileged and headers['Privileged'] = $rt2creds['graphqlApiKey']
  response = HTTParty.post("#{$escholServer}/graphql",
               :headers => headers,
               :body => { variables: varHash, query: query }.to_json)
  response['errors'] and raise("Internal error (graphql): #{response['errors'][0]['message']}")
  response['data']
end

###################################################################################################
def getSession
  if request.env['HTTP_COOKIE'] =~ /JSESSIONID=(\w{32})/
    session = $1
    if $sessions.include?(session)
      puts "Got existing session: #{session}"
      return session
    end
  end

  session = SecureRandom.hex(16).upcase
  $sessions.size >= MAX_SESSIONS and $sessions.shift
  $sessions[session] = { time: Time.now, loggedIn: false }
  headers 'Set-Cookie' => "JSESSIONID=#{session}; Path=/dspace-rest"
  puts "Created new session: #{session}"
  return session
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
      </status>''', {email: $rt2creds['email']})
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
  params['email'] == $rt2creds['email'] && params['password'] == $rt2creds['password'] or halt(401, "Unauthorized.\n")
  $sessions[getSession][:loggedIn] = true
  puts "==> Login ok, setting flag on session."
  "OK\n"
end

###################################################################################################
def verifyLoggedIn
  puts "Verifying login, cookie=#{request.env['HTTP_COOKIE']}"
  $sessions[getSession][:loggedIn] or halt(401, "Unauthorized.\n")
end

###################################################################################################
get "/dspace-rest/collections" do
  verifyLoggedIn
  content_type "text/xml"
  inner = %w{cdl_rw iis_general root}.map { |unitID|
    data = apiQuery("unit(id: $unitID) { items { total } }", { unitID: ["ID!", unitID] }).dig("unit")
    unitID.sub!("root", "jtest")
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
  }
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
get %r{/dspace-rest/(items|handle)/(.*)} do
  #verifyLoggedIn
  puts "FIXME: verifyLoggedIn: items"
  request.path =~ /(qt\w{8})/ or halt(404, "Invalid item ID")
  itemID = $1
  itemFields = %{
    id
    title
    authors {
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
    contributors {
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
    }
    units {
      id
      name
      parents {
        name
      }
    }
    abstract
    added
    bookTitle
    contentLink
    contentType
    disciplines
    embargoExpires
    externalLinks
    pagination
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
  data = apiQuery("item(id: $itemID) { #{itemFields} }", { itemID: ["ID!", "ark:/13030/#{itemID}"] }, true).dig("item")
  data.delete_if{ |k,v| v.nil? || v.empty? }

  metaXML = stripHTML(XmlSimple.xml_out(data, {suppress_empty: nil, noattr: true, rootname: "metadata"}))
  lastMod = Time.parse(data.dig("updated")).strftime("%Y-%m-%d %H:%M:%S")

  collections = (data['units'] || []).map { |unit|
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
        <name><%= unit.dig("parents", 0, "name") + ": " + unit["name"] %></name>
        <type>collection</type>
        <UUID><%= unit["id"] %></UUID>
        <copyrightText/>
        <introductoryText/>
        <numberItems><%= unit.dig("items", "total") %></numberItems>
        <shortDescription><%= unit["id"] %></shortDescription>
        <sidebarText/>
      </parentCollection>''', binding, xml_header: false)
  }.join("\n")

  bitstreams = ""
  if data['contentLink'] && data['contentType'] == "application/pdf"
    bitstreamUUID = data["contentLink"].sub(%r{.*content/},'')
    bitstreams = xmlGen('''
      <bitstreams>
        <link><%= data["contentLink"] %></link>
        <expand>parent</expand>
        <expand>policies</expand>
        <expand>all</expand>
        <name><%= File.basename(data["contentLink"]) %></name>
        <type>bitstream</type>
        <UUID><%= bitstreamUUID %></UUID>
        <bundleName>ORIGINAL</bundleName>
        <description>Accepted version</description>
        <format>Adobe PDF</format>
        <mimeType>application/pdf</mimeType>
        <link><%= data["contentLink"] %></link>
        <sequenceId>-1</sequenceId>
        <sizeBytes>999</sizeBytes>
      </bitstreams>''', binding, xml_header: false)
  end

  content_type "text/xml"
  xmlGen('''
    <item>
      <link>/rest/items/13030/<%= itemID %></link>
      <expand>parentCommunityList</expand>
      <expand>all</expand>
      <handle>13030/<%= itemID %></handle>
      <name><%= data["title"] %></name>
      <type>item</type>
      <%== metaXML %>
      <UUID><%= itemID %></UUID>
      <archived>true</archived>
      <lastModified><%= lastMod %></lastModified>
      <%== collections %>
      <%== collections.gsub("parentCollection", "parentCollectionList") %>
      <withdrawn><%= data.dig("status") == "WITHDRAWN" %></withdrawn>
      <%== bitstreams %>
    </item>''', binding)
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
  puts "Sword post body: #{body.inspect}"
  entry = body.xpath("entry") or raise("can't locate <entry> in request: #{body}")

  # Grab the Elements GUID for this publication
  title = (entry.xpath("title") or raise("can't locate <title> in entry: #{body}")).text
  guid = title[/\b\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\b/] or raise("can't find guid in title #{title.inspect}")

  # Make an eschol ARK for this pub (if we've seen the pub before, the same old ark will be returned)
  ark = mintArk(guid)

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
put "/dspace-rest/items/:itemGUID/metadata" do |itemID|
  # PUT /rest/items/4463d757-868a-42e2-9aab-edc560089ca1/metadata
  # with data <metadataentries><metadataentry><key>dc.type</key><value>Article</value></metadataentry>
  #                            <metadataentry><key>dc.title</key><value>Targeting vivax malaria...
  #                            ...

  # The ID should be an ARK, obtained earlier from the Sword post.
  itemID =~ /^qt\w{8}$/ or raise("itemID #{itemID.inspect} should be an eschol short ark")

  # Grab the body. It should be an XML set of metadata entries.
  request.body.rewind
  body = Nokogiri::XML(request.body.read, nil, "UTF-8", &:noblanks).remove_namespaces!
  puts "dspaceMetaPut: body=#{body.to_xml}"

  # Update the metadata on disk
  checkForMetaUpdate(nil, "ark:/13030/#{itemID}", body, DateTime.now)

  # All done.
  content_type "text/plain"
  nil  # content length zero, and HTTP 200 OK
end

###################################################################################################
post "/dspace-rest/items/:itemGUID/bitstreams" do |shortArk|
  content_type "text/xml"

  shortArk =~ /^qt\w{8}$/ or raise("invalid ARK")

  fileName = params['name'] or raise("missing 'name' param")
  fileVersion = params['description']  # will be missing if user chose '[None]'

  request.body.rewind
  outFilename, size, mimeType = depositFile("ark:/13030/#{shortArk}", fileName, fileVersion, request.body)

  # POST /rest/items/4463d757-868a-42e2-9aab-edc560089ca1/bitstreams?name=anvlspec.pdf&description=Accepted%20version
  # TODO - customize raw response
  xmlGen('''
    <bitstream>
      <link>/rest/bitstreams/<%=shortArk%>/<%=fileName%></link>
      <expand>parent</expand>
      <expand>policies</expand>
      <expand>all</expand>
      <name><%=outFilename%></name>
      <type>bitstream</type>
      <UUID><%=shortArk%>/<%=outFilename%></UUID>
      <bundleName>ORIGINAL</bundleName>
      <description><%=fileVersion%></description>
      <mimeType><%=mimeType%></mimeType>
      <retrieveLink>/rest/bitstreams/<%=shortArk%>/<%=outFilename%></retrieveLink>
      <sequenceId>-1</sequenceId>
      <sizeBytes><%=size%></sizeBytes>
    </bitstream>''', binding)
end

###################################################################################################
get "/dspace-rest/bitstreams/:itemID/:filename/policy" do |itemID, filename|
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  [200, xmlGen('''
    <resourcePolicies>
      <resourcepolicy>
        <action>READ</action>
        <groupId>8dae5664-cf16-4623-9451-2b094505bca6</groupId>
        <id>32</id>
        <resourceId>#{itemID}/#{filename}</resourceId>
        <resourceType>bitstream</resourceType>
        <rpType>TYPE_INHERITED</rpType>
      </resourcepolicy>
    </resourcePolicies>''', binding)]
end

###################################################################################################
delete "/dspace-rest/bitstreams/:itemID/:filename/policy/32" do |itemID, filename|
  # After redepositing a file, Elements goes and deletes the policy from the new file.
  # Not sure what's going on here. Fake the response for now.
  [204, "Deleted."]
end

###################################################################################################
post "/dspace-swordv2/edit/:itemGUID" do |itemID|
  # POST /dspace-swordv2/edit/4463d757-868a-42e2-9aab-edc560089ca1
  # Not sure what we receive here, nor what we should reply. Original log was incomplete
  # because Sword rejected the URL due to misconfiguration.

  itemID =~ /^qt\w{8}$/ or raise("itemID #{itemID.inspect} should be an eschol short ark")

  # Maybe this is a signal that it's time to publish this thing?
  approveItem("ark:/13030/#{itemID}", nil, false)

  # Elements doesn't seem to care what we return, as long as it's XML. Hmm.
  content_type "application/atom+xml; type=entry;charset=UTF-8"
  [200, xmlGen('''
    <entry xmlns="http://www.w3.org/2005/Atom"
    </entry>''', binding, xml_header: false)]
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
            <setSpec>jtest</setSpec>
            <setName>jtest</setName>
          </set>
        </ListSets>
      </OAI-PMH>''', binding)
  else
    if params['set'] == 'jtest'
      params['verb'] == 'ListIdentifiers' and params['from'] = "2018-05-04T10:20:57Z"
      params['set'] = "everything"
    else
      params['verb'] == 'ListIdentifiers' and params.delete('from') # Disable differential harvest for now
    end

    # Proxy the OAI query over to the eschol API server, and return its results
    response = HTTParty.get("#{$escholServer}/oai", query: params,
                headers: { 'Privileged' => $rt2creds['graphqlApiKey'] })
    content_type response.headers['Content-Type']
    return [response.code, response.body]
  end
end
