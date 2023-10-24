###################################################################################################
# Translation logic: Elements flat metadata to eSchol API JSON

require 'date'
require 'sequel'

require_relative './sanitize.rb'

###################################################################################################
# Connect to the eschol5 database server
DB = Sequel.connect({
  "adapter"  => "mysql2",
  "host"     => ENV["ESCHOL_DB_HOST"] || raise("missing env ESCHOL_DB_HOST"),
  "port"     => ENV["ESCHOL_DB_PORT"] || raise("missing env ESCHOL_DB_PORT").to_i,
  "database" => ENV["ESCHOL_DB_DATABASE"] || raise("missing env ESCHOL_DB_DATABASE").to_i,
  "username" => ENV["ESCHOL_DB_USERNAME"] || raise("missing env ESCHOL_DB_USERNAME"),
  "password" => ENV["ESCHOL_DB_PASSWORD"] || raise("missing env ESCHOL_DB_HOST") })

###################################################################################################
# Elements group IDs, used to determine into which campus postprint bucket to deposit.
$groupToCampus = { 684 => 'lbnl',
                   430 => 'ucb',
                   431 => 'ucd',
                   3   => 'uci',
                   4   => 'ucla',
                   400 => 'ucm',
                   432 => 'ucr',
                   282 => 'ucsd',
                   2   => 'ucsf',
                   286 => 'ucsb',
                   280 => 'ucsc',
                   1254 => 'anrcs',
                   1164 => 'ucop' }

$groupToRGPO = { 784 => 'CBCRP',
                 785 => 'CHRP',
                 787 => 'TRDRP',
                 783 => 'TRDRP',
                 786 => 'UCRI' }

###################################################################################################
$repecIDs = {}
MAX_REPEC_IDS = 10

###################################################################################################
def guessMimeType(filePath)
  Rack::Mime.mime_type(File.extname(filePath))
end

###################################################################################################
def isPDF(filename)
  return guessMimeType(filename) == "application/pdf"
end

###################################################################################################
def isWordDoc(filename)
  return guessMimeType(filename) =~ %r{application/(msword|rtf|vnd.openxmlformats-officedocument.wordprocessingml.document)}
end

###################################################################################################
def convertPubType(pubTypeStr)
  case pubTypeStr
    when %r{^(journal-article|conference|conference-proceeding|internet-publication|scholarly-edition|report|preprint)$}; 'ARTICLE'
    when %r{^(dataset|poster|media|presentation|other)$}; 'NON_TEXTUAL'
    when "book"; 'MONOGRAPH'
    when "chapter"; 'CHAPTER'
    else raise "Can't recognize pubType #{pubTypeStr.inspect}" # Happens when Elements changes or adds types
  end
end

###################################################################################################
def getDefaultPeerReview(elementsIsReviewed, elementsPubType, elementsPubStatus)
   
  # If elementsIsReveiewed nil is considered false
  peerReviewBool = (elementsIsReviewed == "true")? true : false

  # If it's an article without a specified "is reviewed"
  if (elementsPubType == "journal-article" && elementsIsReviewed == nil)

    # Accepted & published works are "true", all others false
    if (elementsPubStatus == "Accepted" ||
      elementsPubStatus == "Published" ||
      elementsPubStatus == "Published online")
      return(true)
    else
      return(false)
    end

  # All other pub types (incl. articles w/ specified "is reviewed") 
  # Use the specified value, null = false.
  # The user can edit this with a manual record if they want to.
  else
    return(peerReviewBool)
  end

end

###################################################################################################
def convertKeywords(kws)
  # Transform "1505 Marketing (for)" to just "Marketing"
  kws.map { |kw|
    # Remove scheme at end, and remove initial series of digits
    kw.sub(%r{ \([^)]+\)$}, '').sub(%r{^\d+ }, '')
  }.uniq
end

###################################################################################################
def parseMetadataEntries(feed)
  metaHash = {}
  feed.xpath(".//metadataentry").each { |ent|
    key = ent.text_at('key')
    value = ent.text_at('value')
    if key == 'keywords'
      metaHash[key] ||= []
      metaHash[key] << value
    elsif key == 'proceedings'
      metaHash.key?(key) or metaHash[key] = value   # Take first one only (for now at least)
    else
      metaHash.key?(key) and raise("double key #{key}")
      metaHash[key] = value
    end
  }
  return metaHash
end

###################################################################################################
def convertPubDate(pubDate)
  case pubDate
    when /^\d\d\d\d-[01]\d-[0123]\d$/; pubDate
    when /^\d\d\d\d-[01]\d$/;          "#{pubDate}-01"
    when /^\d\d\d\d$/;                 "#{pubDate}-01-01"
    when nil;                          Date.today.iso8601
    else;                              raise("Unrecognized date.issued format: #{pubDate.inspect}")
  end
end

###################################################################################################
def convertFileVersion(fileVersion)
  case fileVersion
    # Pre-v6.8 terms
    when /(Author's final|Submitted) version/; 'AUTHOR_VERSION'
    when "Published version"; 'PUBLISHER_VERSION'
    # Post-v6.8 terms
    when /(Publisher's|Published) version/; 'PUBLISHER_VERSION'
    when /(Accepted|Submitted) version*/,
         "Author's accepted manuscript";'AUTHOR_VERSION'
    else raise "Unrecognized file version '#{fileVersion}'"
  end
end

###################################################################################################
def assignSeries(data, completionDate, metaHash)
  # See https://docs.google.com/document/d/1U_DG-_iPOnS_Rp8Wu6COIgcNcicDtonOM9aZCCsJoQI/edit
  # for a prose description of our method here.

  # In general we want to retain existing units. Grab a list of those first.
  # We use a Hash, which preserves order of insertion (vs. Set which seems to but isn't guaranteed)
  series = {}
  puts("Units: #{data[:units]}")
  (data[:units] || []).each { |unit|
    # Filter out old RGPO errors
    if !(unit =~ /^(cbcrp_rw|chrp_rw|trdrp_rw|ucri_rw)$/)
      series[unit] = true
    end
  }

  # Make a list of campus associations using the Elements groups associated with the incoming item.
  # Format of the groups string is e.g. "435:UC Berkeley (senate faculty)|430:UC Berkeley|..."
  groupStr = metaHash.delete("groups") or raise("missing 'groups' in deposit data")
  groups = Hash[groupStr.split("|").map { |pair|
    pair =~ /^(\d+):(.*)$/ or raise("can't parse group pair #{pair.inspect}")
    [$1.to_i, $2]
  }]
  
  # We use two sets here to facilitate regex-based sorting 
  # when we combined the two into campusSeries (and convert to array)
  campusSeries = Set.new
  rgpoUnits = Set.new

  puts("group check")
  puts(groups)

  # Funder display names include texts like TRDRP, CHRP, etc.
  funderDisplayNames = metaHash.delete("funder-type-display-name")&.split("|")

  groups.each { |groupID, groupName|
  
    puts("Group check: #{groupID}, #{groupName}")

    # Regular campus and LBL
    if $groupToCampus[groupID]
      (groupID == 684) ? campusSeries << "lbnl_rw" : campusSeries << "#{$groupToCampus[groupID]}_postprints"

    # RGPO logic: groupID is an RGPO group, and pub is grant-funded
    elsif ($groupToRGPO[groupID] && completionDate >= Date.new(2017,1,8) && data[:grants])
       
      # if the funder display names include RGPO strings (TRDRP, etc),
      # add that series and rgpo_rw. Otherwise, it's not an RGPO grant so ignore it.
      funderDisplayNames.each { |displayName|

        if displayName.include?($groupToRGPO[groupID])
          puts("RGPO grant found!!: #{displayName} / #{$groupToRGPO[groupID]}")
          rgpoUnits << "#{$groupToRGPO[groupID].downcase}_rw"
          rgpoUnits << "rgpo_rw"
        else
          puts("Not an RGPO grant: #{displayName} / #{$groupToRGPO[groupID]}")
        end
      }

    end
  }

  # If the user is non-uc and no has units, add rgpo_rw
  if (rgpoUnits.empty?() && campusSeries.empty?() && groups.key?(779))
    rgpoUnits << "rgpo_rw"
  end

  # Check the two sets
  puts("RGPO Units check: #{rgpoUnits.to_a.join(',')}")
  puts("Campus series check: #{campusSeries.to_a.join(',')}")

  # Combine the two sets and convert to array 
  campusSeries = (campusSeries | rgpoUnits).to_a
  puts("Combined campusSeries array: #{campusSeries}")
  
  # Add campus series in sorted order (special: always sort lbnl first, and rgpo last)
  rgpoPat = Regexp.compile("^(#{rgpoUnits.to_a.join("|")})$")
  ucPPPat = Regexp.compile('^uc[\w]{1,2}_postprints')
  # puts("rgpoPat: #{rgpoPat}")
  # old sort: a.sub('lbnl','0').sub(rgpoPat,'zz') <=> b.sub('lbnl','0').sub(rgpoPat,'zz')
  campusSeries.sort { |a, b|
    a.sub(ucPPPat,'0').sub('lbnl','1').sub(rgpoPat,'zz') <=> b.sub(ucPPPat,'0').sub('lbnl','1').sub(rgpoPat,'zz')
  }.each { |s|
    series.key?(s) or series[s] = true
  }

  # Figures out which departments correspond to which Elements groups.
  # Note: this query is so fast (< 0.01 sec) that it's not worth caching.
  # Note: departments always come after campus
  depts = Hash[DB.fetch("""SELECT id unit_id, attrs->>'$.elements_id' elements_id FROM units
                           WHERE attrs->>'$.elements_id' is not null""").map { |row|
    [row[:elements_id].to_i, row[:unit_id]]
  }]

  # Add any matching departments for this publication
  deptSeries = groups.map { |groupID, groupName| depts[groupID] }.compact

  # Add department series in sorted order (and avoid dupes)
  deptSeries.sort.each { |s| series.key?(s) or series[s] = true }

  # Re-sort the series keys before passing
  seriesKeys = series.keys
  seriesKeys = seriesKeys.sort { |a, b| 
    a.sub(ucPPPat,'0').sub('lbnl','1').sub(rgpoPat,'zz') <=> b.sub(ucPPPat,'0').sub('lbnl','1').sub(rgpoPat,'zz')
  }

  puts(seriesKeys)
  return data[:units] = seriesKeys
end

###################################################################################################
def getCompletionDate(oldData, metaHash)
  # If there's a recorded escholPublicationDate, use that.
  oldData[:published] and return oldData[:published]

  # Otherwise, use the deposit date from the feed
  feedCompleted = metaHash['deposit-date'] or raise("can't find deposit-date")
  return Date.parse(feedCompleted, "%d-%m-%Y")
end

###################################################################################################
def convertFunding(metaHash)
  funderNames = metaHash.delete("funder-name").split("|")
  funderIds   = metaHash.delete("funder-reference")&.split("|")
  if funderIds.nil?
     return nil
  end 
  return funderNames.map.with_index { |name, idx| { reference: funderIds[idx], name: name } }.select{|r| r[:reference] != nil and !r[:reference].empty?}
end

###################################################################################################


def convertOALocation(ark, metaHash, data)
  loc = metaHash.delete("oa-location-url")
  if loc =~ %r{search.library.(berkeley|ucla|ucr|ucdavis|ucsb|ucsf).edu} or loc =~ %r{primo.exlibrisgroup.com} or loc =~ %r{search-library.ucsd.edu}

    userErrorHalt(ark, "The link you provided may not be accessible to readers outside of UC. \n" +
    "Please provide a link to an open access version of this article.")
  end
  if loc =~ %r{escholarship.org}
    userErrorHalt(ark, "The link you provided is to an existing eScholarship item. \n" +
                       "There is no need to re-deposit this item.")
  end
  data[:externalLinks] ||= []
  data[:externalLinks] << loc
end

###################################################################################################
def assignEmbargo(metaHash)
  reqPeriod = metaHash.delete("requested-embargo.display-name")
  if metaHash.delete("confidential") == "true"
    return '2999-12-31' # this should be long enough to count as indefinite
  else
    case reqPeriod
      when nil, /Not known|No embargo|Unknown/
        return nil
      when /Indefinite/
        return '2999-12-31' # this should be long enough to count as indefinite
      when /^(\d+) month(s?)/
        return (Date.today >> ($1.to_i)).iso8601
      else
        raise "Unknown embargo period format: '#{reqPeriod}'"
    end
  end
end

###################################################################################################
def convertPubStatus(elementsStatus)
  case elementsStatus
    when /None|Unpublished|Submitted/i
      'INTERNAL_PUB'
    when /Published/i
      'EXTERNAL_PUB'
    else
      'EXTERNAL_ACCEPT'
  end
end

###################################################################################################
# Lookup, and cache, a RePEc ID for the given pub. We cache to speed the case of checking and
# immediately updating the metadata.
def lookupRepecID(elemPubID)
  if !$repecIDs.key?(elemPubID)
    # The only way we know of to get the RePEc ID is to ask the Elements API.
    apiHost = ENV['ELEMENTS_API_URL'] || raise("missing env ELEMENTS_API_URL")
    resp = HTTParty.get("#{apiHost}/publications/#{elemPubID}", :basic_auth =>
      { :username => ENV['ELEMENTS_API_USERNAME'] || raise("missing env ELEMENTS_API_USERNAME"),
        :password => ENV['ELEMENTS_API_PASSWORD'] || raise("missing env ELEMENTS_API_PASSWORD") })
    resp.code == 404 and return nil  # sometimes Elements does meta update on non-existent pub, e.g 2577213. Weird.
    resp.code == 410 and return nil  # sometimes Elements does meta update on deleted pub, e.g 2564054. Weird.
    resp.code == 200 or raise("Updated message : Got error from Elements API #{apiHost} for pub #{elemPubID}: #{resp}")

    data = Nokogiri::XML(resp.body).remove_namespaces!
    repecID = data.xpath("//record[@source-name='repec']").map{ |r| r['id-at-source'] }.compact[0]

    $repecIDs.size >= MAX_USER_ERRORS and $repecIDs.shift
    $repecIDs[elemPubID] = repecID
  end
  return $repecIDs[elemPubID]
end

###################################################################################################
# Take feed XML from Elements and make an eschol JSON record out of it. Note that if you pass
# existing eschol data in, it will be retained if Elements doesn't override it.
def elementsToJSON(oldData, elemPubID, submitterEmail, metaHash, ark, feedFile)

  # eSchol ARK identifier (provisional ID minted previously for new items)
  data = oldData ? oldData.clone : {}
  data[:id] = ark

  # Identify the source system
  data[:sourceName] = 'elements'
  data[:sourceID] = elemPubID
  data[:sourceFeedLink] = "#{$submitServer}/bitstreamTmp/#{feedFile}"

  # Object type, flags, status, etc.
  elementsPubType = metaHash.delete('object.type') || raise("missing object.type")
  elementsPubStatus = metaHash['publication-status'] || nil
  elementsIsReviewed = metaHash.delete('is-reviewed') || nil
  
  data[:isPeerReviewed] = getDefaultPeerReview(elementsIsReviewed, elementsPubType, elementsPubStatus)

  data[:type] = convertPubType(elementsPubType)
  data[:isPeerReviewed] = true  # assume all Elements items are peer reviewed
  if (elementsPubType == 'preprint' ||
     (elementsPubType == 'journal-article' &&
       (elementsPubStatus == 'In preparation' ||
        elementsPubStatus == 'Submitted' ||
        elementsPubStatus == 'Unpublished') ) )  
    data[:isPeerReviewed] = false  # assume preprints are not peer reviewed
  end  
  data[:pubRelation] = convertPubStatus(metaHash.delete('publication-status'))
  data[:embargoExpires] = assignEmbargo(metaHash)

  # Author and editor metadata.
  metaHash['authors'] && data[:authors] = transformPeople(metaHash.delete('authors'), nil)
  if metaHash['editors'] || metaHash['advisors']
    contribs = []
    metaHash['editors'] and contribs += (transformPeople(metaHash.delete('editors'), 'EDITOR') || [])
    metaHash['advisors'] and contribs += (transformPeople(metaHash.delete('advisors'), 'ADVISOR') || [])
    !contribs.empty? and data[:contributors] = contribs
  end

  # Other top-level fields
  metaHash.key?('title') and data[:title] = sanitizeHTML(metaHash.delete('title')).gsub(/\s+/, ' ').strip
  metaHash.key?('abstract') and data[:abstract] = sanitizeHTML(metaHash.delete('abstract'))
  data[:localIDs] = []
  metaHash.key?('doi') and data[:localIDs] << { id: metaHash.delete('doi'), scheme: 'DOI' }
  data[:localIDs] << {id: elemPubID, scheme: 'OA_PUB_ID'}
  metaHash.key?('fpage') and data[:fpage] = metaHash.delete('fpage')
  metaHash.key?('lpage') and data[:lpage] = metaHash.delete('lpage')
  metaHash.key?('keywords') and data[:keywords] = convertKeywords(metaHash.delete('keywords'))
  if metaHash.key?('requested-reuse-licence.short-name')
    if metaHash['requested-reuse-licence.short-name'] != "No Licence"
      ccCode = metaHash.delete('requested-reuse-licence.short-name')
      data[:rights] = "https://creativecommons.org/licenses/#{ccCode.sub("CC ", "").downcase}/4.0/"
    end
  end
  metaHash.key?('funder-name') and data[:grants] = convertFunding(metaHash)
  #metaHash.key?('funder-type-display-name')

  # Context
  assignSeries(data, getCompletionDate(data, metaHash), metaHash)
  lookupRepecID(elemPubID) and data[:localIDs] << { scheme: 'OTHER_ID', subScheme: 'repec', id: lookupRepecID(elemPubID) }
  metaHash.key?("report-number") and data[:localIDs] << {
    scheme: 'OTHER_ID', subScheme: 'report', id: metaHash.delete('report-number')
  }
  metaHash.key?("issn") and data[:issn] = metaHash.delete("issn")
  metaHash.key?("isbn-13") and data[:isbn] = metaHash.delete("isbn-13") # for books and chapters
  metaHash.key?("journal") and data[:journal] = metaHash.delete("journal")
  metaHash.key?("proceedings") and data[:proceedings] = metaHash.delete("proceedings")
  metaHash.key?("volume") and data[:volume] = metaHash.delete("volume")
  metaHash.key?("issue") and data[:issue] = metaHash.delete("issue")
  metaHash.key?("parent-title") and data[:bookTitle] = metaHash.delete("parent-title")  # for chapters 
  metaHash.key?("oa-location-url") and convertOALocation(ark, metaHash, data)
  data[:ucpmsPubType] = elementsPubType

  # History
  data[:published] = convertPubDate(metaHash.delete('publication-date'))
  data[:submitterEmail] = submitterEmail

  # Custom Citation Field
  metaHash.key?("custom-citation") and data[:customCitation] = metaHash.delete("custom-citation")

  # All done.
  return data
end

###################################################################################################
def transformPeople(pieces, role)

  # Now build the resulting UCI author records.
  people = []
  person = nil
  pieces.split(/\|\| *\n/).each { |line|
    line =~ %r{\[([-a-z]+)\] ([^|]*)} or raise("can't parse people line #{line.inspect}")
    field, value = $1, $2
    case field
      when 'start-person'
        person = {}
      when 'lastname'
        person[:nameParts] ||= {}
        person[:nameParts][:lname] = value
      when 'firstnames', 'initials'
        # Prefer longer of firstname or initials
        if !person[:nameParts][:fname] || person[:nameParts][:fname].size < value.size
          person[:nameParts][:fname] = value
        end
      # Fix for filtering non-UC author emails
      when 'resolved-user-email'
        person[:email] = value
      when 'email-address'
        # Older version of above
        # do nothing for now.
      when 'resolved-user-orcid'
        person[:orcid] = value
      when 'identifier'
        #puts "TODO: Handle identifiers like #{value.inspect}"
        if value.include? "(orcid)"
          # Orcids passed as: "xxxx-xxxx-xxxx-xxxx (orcid)" 
          person[:orcid] = value.split[0]
        end
      when 'end-person'
        if !person.empty?
          role and person[:role] = role
          people << person
        end
        person = nil
      when 'address'
        # e.g. "University of California, Berkeley\nBerkeley\nUnited States"
        # do nothing with it for now
      else
        raise("Unexpected person field #{field.inspect}")
    end
  }

  return people.empty? ? nil : people
end

###################################################################################################
# DS 2023-10-24
# This code taxes the existing simple
def mimicDspaceXMLOutput(input_xml)

  # -------------------------
  def nest_metadata_simple(node, document)

    # Create the new metadataentry node
    metadata_node = Nokogiri::XML::Node.new "metadata", document

    # Add the key and value as children nodes
    meta_key = Nokogiri::XML::Node.new "key", document
    meta_key.content = node.name

    meta_value = Nokogiri::XML::Node.new "value", document
    meta_value.content = node.text

    metadata_node.add_child(meta_key)
    metadata_node.add_child(meta_value)

    return metadata_node

  end

  # -------------------------
  def convert_local_id(node, document)

    # Create the new metadataentry node
    metadata_node = Nokogiri::XML::Node.new "metadata", document

    meta_key = Nokogiri::XML::Node.new "key", document
    meta_key.content = "elements-pub-id"

    meta_value = Nokogiri::XML::Node.new "value", document
    meta_value.content = node.css("id").text

    metadata_node.add_child(meta_key)
    metadata_node.add_child(meta_value)

    return metadata_node

  end

  # -------------------------
  def nest_metadata_authors(authors_node, document)

    def get_new_vt(new_tag, new_text)
      return("[" << new_tag << "] " << new_text << "|| \n")
    end

    # Create the new metadataentry node
    metadata_node = Nokogiri::XML::Node.new "metadata", document

    # Text string for metadata value
    value_text = ""

    # Map for translating escholarship node nades to elements
    authorMap = Struct.new(:xpath, :elements_name)
    author_children_array = Array[
      authorMap.new('nameParts/lname', 'lastname'),
      authorMap.new('nameParts/fname', 'firstnames'),
      authorMap.new('nameParts/fname', 'initials'),
      authorMap.new('email', 'resolved-user-email'),
      authorMap.new('orcid', 'resolved-user-orcid'),
    ]

    # Loop the author nodes and assemble the value text
    authors_node.xpath("nodes").each do |author_node|

      value_text << "\n[start-person] ||\n"

      author_children_array.each do |aMap|

        if aMap.elements_name != "initials"
          child_text = author_node.xpath(aMap.xpath).text
          (value_text << get_new_vt(aMap.elements_name, child_text)) unless child_text == ""

        else
          # The initials calculation is slightly hacky
          child_text = author_node.xpath(aMap.xpath).text
          child_text = child_text.upcase()[0]
          (value_text << get_new_vt(aMap.elements_name, child_text)) unless child_text == ""

        end

      end

      value_text << "[end-person] \n"

    end

    # Add the key and value as children nodes
    meta_key = Nokogiri::XML::Node.new "key", document
    meta_key.content = "authors"

    meta_value = Nokogiri::XML::Node.new "value", document
    meta_value.content = value_text

    metadata_node.add_child(meta_key)
    metadata_node.add_child(meta_value)

    return metadata_node

  end


  # -------------------------  
  # Main function
  # noko_xml = input_xml
  noko_xml = Nokogiri::XML(input_xml)

  # Loop the nested metadata nodes, nesting or removing them as needed
  noko_xml.xpath("/root/*").each do |node|

    # Switch for certain nodes which return nested results
    case node.name

    when "authors"
      node.replace(nest_metadata_authors(node, noko_xml))

    when "localIDs"
      if (node.css("scheme").text == "OA_PUB_ID")
        node.replace(convert_local_id(node, noko_xml))
      else
        node.unlink()
      end

    when "key", "value", "units"
      node.unlink()

    else
      node.replace(nest_metadata_simple(node, noko_xml))

    end

  end

  return(noko_xml.xpath("/root/*").to_s())

end