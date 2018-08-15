
###################################################################################################
# External code modules
require 'cgi'
require 'fileutils'
require 'open3'
require 'yaml'
require 'open-uri'
require 'open4'
require 'netrc'
require 'sqlite3'
require 'equivalent-xml'
require 'net/smtp'
require 'unindent'
require "#{$espylib}/ark.rb"
require "#{$espylib}/subprocess.rb"
require "#{$espylib}/xmlutil.rb"
require "#{$espylib}/stringutil.rb"
require "#{$subiDir}/lib/rawItem.rb"
require "#{$subiDir}/lib/subiGuts.rb"

###################################################################################################
# Use absolute paths to executables so we don't depend on PATH env (monit doesn't give us a good PATH)
$java = "/usr/pkg/java/oracle-8/bin/java"
$libreOffice = "/usr/pkg/bin/soffice"

# Fix up LD_LIBRARY_PATH so that pdfPageSizes can run successfully
ENV['LD_LIBRARY_PATH'] = (ENV['LD_LIBRARY_PATH'] || '') + ":/usr/pkg/lib"

$scanMode = false

# We'll need to look things up in the arks database, so open it now.
$arkDb = SQLite3::Database.new("#{$controlDir}/db/arks.db")
$arkDb.busy_timeout = 30000

###################################################################################################
# Strings to pick out from <organisational-details>/</group> to determine campus.
$campusNames = { 'Lawrence Berkeley Lab' => 'lbnl',
                 'UC Berkeley'           => 'ucb',
                 'UC Davis'              => 'ucd',
                 'UC Irvine'             => 'uci',
                 'UC Los Angeles'        => 'ucla',
                 'UC Merced'             => 'ucm',
                 'UC Riverside'          => 'ucr',
                 'UC San Diego'          => 'ucsd',
                 'UC San Francisco'      => 'ucsf',
                 'UC Santa Barbara'      => 'ucsb',
                 'UC Santa Cruz'         => 'ucsc' }

###################################################################################################
# Make a filename from the outside safe for use as a file on our system.
def sanitizeFilename(fn)
  fn.gsub(/[^-A-Za-z0-9_.]/, "_")
end

###################################################################################################
# Create a new ARK on our system.
def mintArk(elementsGUID)
  ark = `#{$controlDir}/tools/mintArk.py elements #{elementsGUID} incomplete`.strip()
  return (ark =~ %r<^ark:/?13030/\w{10}$>) ? ark : raise("bad result '#{ark}' from mintArk")
end

###################################################################################################
# All kinds of circumstances can cause an item to be incomplete during the many stages of
# depositing from Elements. We need to clean up after.
def destroyOnFail(ark, &blk)
  # What's all this business with "unfinished" and "ensure" below? Why not just use begin/rescue?
  # It's because Sinatra's "halt" (which is super handy) doesn't actually use exceptions; instead
  # it uses throw/catch which is a completely separate mechanism in Ruby from raise/rescue.
  # Who knew. Kinda an ugly corner of the language.
  result = "unfinished"
  begin
    result = yield blk
    return result
  ensure
    if result == "unfinished"
      # It shouldn't have been published up to this point, but if it was, don't destroy it.
      marker = $arkDb.get_first_value("SELECT external_url FROM arks WHERE id=?", normalizeArk(ark))
      marker or raise("Strange, ARK should be in db: #{ark}")
      if marker == "incomplete"
        # Not yet published - destroy it.
        puts "Unable to complete processing item #{ark.inspect} - destroying partial item."
        begin
          `#{$controlDir}/tools/unharvestItem.py #{getShortArk(ark)}`
        rescue => e
          puts "Secondary failure during unharvest: #{e}"
        end
      end
    end
  end
end

###################################################################################################
def isPDF(filename)
  return SubiGuts.guessMimeType(filename) == "application/pdf"
end

###################################################################################################
def isWordDoc(filename)
  return SubiGuts.guessMimeType(filename) =~
    %r{application/(msword|rtf|vnd.openxmlformats-officedocument.wordprocessingml.document)}
end

###################################################################################################
# If the user uploads a Word doc, convert it to a PDF. If it's already a PDF, just copy it. In
# either case, return the path to the new file. If it's not Word or PDF, return nil.
def convertToPDF(ark, uploadedPath)
  outPath = arkToFile(ark, "next/content/base.pdf")

  # If already a PDF, just return it.
  if isPDF(uploadedPath)
    FileUtils.copy(uploadedPath, outPath)
    return outPath
  end

  # If it's a Word doc, convert with LibreOffice
  if isWordDoc(uploadedPath)
    tmpFile = uploadedPath.sub(File.extname(uploadedPath), '.pdf')
    File.delete(tmpFile) if File.exist? tmpFile
    checkCall([$libreOffice, '--headless', '--convert-to', 'pdf', '-outdir', arkToFile(ark, 'next/content'), uploadedPath])
    File.exist? tmpFile or raise "LibreOffice did not produce expected file '#{tmpFile}'"
    File.rename(tmpFile, outPath)
    return outPath
  end

  # None of the above. We can't convert it.
  return nil

end

###################################################################################################
# If the user uploads a Word doc, convert it to a PDF. If it's already a PDF, just copy it. In
# either case, return the path to the new file. If it's not Word or PDF, return nil.
def generatePreviewData(ark, pdfPath)
  begin
    sizesPath = arkToFile(ark, "next/rip/base.pageSizes.xml", true)
    puts "Sizing: #{pdfPath} -> #{sizesPath}"
    File.open(sizesPath, 'wb') { |io|
      Open4.spawn(["/usr/pkg/bin/pdfPageSizes", pdfPath],
                  :timeout=>30, # limit to 30 secs to avoid user thinking we hung
                  :stdout=>io)
    }
  rescue
    # Print a warning to the log but do nothing else. It'll get sized eventually when the item
    # is published.
    puts "Warning: pdfPageSizes timed out on #{pdfPath}"
  end

  begin
    coordPath = arkToFile(ark, "next/rip/base.textCoords.xml", true)
    puts "Ripping: #{pdfPath} -> #{coordPath}"
    Open4.spawn(["/usr/pkg/bin/pdfToTextCoords", pdfPath, coordPath],
                :timeout=>30) # limit to 30 secs to avoid user thinking we hung
  rescue
    # Print a warning to the log but do nothing else. It'll get sized eventually when the item
    # is published.
    puts "Warning: pdfToTextCoords timed out on #{pdfPath}"
  end
end

###################################################################################################
def isModifiableItem(ark)

  # We support modifying items that:
  # 1. aren't imported, or
  # 2. are campus postprints

  # If no existing metadata, it's definitely not imported, and is thus modifiable
  ark or return true
  metaPath = arkToBestFile(ark, "meta/base.meta.xml")
  metaPath or return true
  File.exists?(metaPath) or return true

  # If there's a source element, oa_harvester indicates stuff from Elements. We consider it to be
  # always ok to modify Elements stuff using Elements.
  meta = fileToXML(metaPath).root
  source = meta.text_at("source")
  return true if source == 'oa_harvester'

  # Things that didn't come from Subi or bepress (such as ojs, springer) can't be considered
  # campus postprints. So they can't be modified.
  return false unless source =~ /^(subi|repo)$/

  # Okay, grab the entity and check if it's a campus postprint.
  entity = meta.text_at("context/entity/@id")
  return true if entity =~ /^(ucb|ucd|uci|ucla|ucm|ucr|ucsd|ucsf|ucsb|ucsc|ucop)_postprints$/

  # Subi items other than campus postprints cannot be modified
  return false
end

###################################################################################################
def depositFile(ark, filename, fileVersion, inStream)

  if !(isModifiableItem(ark))
    userErrorHalt("Cannot use Elements to change a non-campus-postprint imported from eSchol")
  end

  # User must select a version
  fileVersion or userErrorHalt(ark, "You must choose a 'File version'.")

  # Get rid of any weird chars in the filename
  filename = sanitizeFilename(filename)

  # Create a next directory if the item has been published
  editItem(ark)

  # Save the file data in the appropriate place.
  if fileVersion == 'Supporting information'
    uploadedPath = arkToFile(ark, "next/content/supp/#{filename}", true)
    updType = "supp"
  else
    # If user tries to upload something we can't use as a content doc, always treat it as supplemental.
    if !(isPDF(filename) || isWordDoc(filename))
      userErrorHalt(ark, "Main content document must be PDF or Word format.")
    end
    uploadedPath = arkToFile(ark, "next/content/#{filename}", true)
    updType = "content"
  end
  File.open(uploadedPath, "wb") { |io| FileUtils.copy_stream(inStream, io) }

  # If the file looks like a PDF, make sure the Unix 'file' command agrees.
  uploadedMimeType = SubiGuts.guessMimeType(uploadedPath)
  if uploadedMimeType =~ /pdf/
    if !(checkOutput(['/usr/bin/file', '--brief', uploadedPath]) =~ /PDF/i)
      userErrorHalt(ark, "Invalid PDF file.")
    end
  end

  # Insert UCI metadata for the uploaded file
  outMimeType = uploadedMimeType
  outSize = File.size(uploadedPath)
  editXML(arkToFile(ark, "next/meta/base.meta.xml")) do |meta|
    partialUploadedPath = uploadedPath.sub(%r{.*/content/}, 'content/')
    contentEl = meta.find! 'content', before:'context'

    # Content file processing
    if updType == 'content'
      pdfPath = convertToPDF(ark, uploadedPath)  # TODO: If this fails, email eschol staff

      pdfPath and generatePreviewData(ark, pdfPath)
      partialPdfPath = pdfPath.sub(%r{.*/content/}, 'content/')
      # Remove existing file and its element - we will replace them
      contentEl.xpath('file/native/file[@path]') do |nfEl|
        if nfEl[:path] != partialUploadedPath
          nfPath = arkToFile(ark, nfEl[:path])
          File.delete nfPath if File.exist? nfPath
        end
      end
      contentEl.xpath('file').remove
      # Make a new 'native' file element
      contentEl.build { |xml|
        xml.file(path:partialPdfPath) {
          xml.mimeType SubiGuts.guessMimeType(pdfPath)
          xml.fileSize SubiGuts.getHumanSize(pdfPath)
          xml.native(path:partialUploadedPath) {
            xml.mimeType uploadedMimeType
            xml.fileSize SubiGuts.getHumanSize(uploadedPath)
            xml.originalName File.basename(uploadedPath)
          }
        }
      }
    elsif updType == 'supp'
      # Supplemental file processing (for now we also treat non-PDF content files as supp)
      suppEl = contentEl.find! 'supplemental'
      # Remove existing file element of the same path (if any) - we will replace it
      suppEl.xpath("file[@path='#{partialUploadedPath}']").remove
      # Make a new file element
      suppEl.build { |xml|
        xml.file(path:partialUploadedPath) {
          xml.mimeType uploadedMimeType
          xml.fileSize SubiGuts.getHumanSize(uploadedPath)
        }
      }
    end
  end

  return filename, outSize, outMimeType
end

###################################################################################################
# Find the best version of a file. E.g. if subPath is "content/base.meta.xml", we will search:
#   mainDir/.../item/content/base.meta.xml
#   mainDir/.../item/next/content/base.meta.xml
#   sequesterDir/.../item/content/base.meta.xml
#   sequesterDir/.../item/next/content/base.meta.xml
# Returns the first found, or nil if none are found.
def arkToBestFile(ark, subPath)
  # Next dir
  path = arkToFile(ark, "next/#{subPath}")
  return path if File.file? path

  # Main dir
  path = arkToFile(ark, subPath)
  return path if File.file? path

  # Sequester versions of those
  if SubiGuts.isSequestered(ark)
    path = arkToFile(ark, "next/#{subPath}").sub('/data/', '/data_sequester/')
    return path if File.file? path

    path = arkToFile(ark, subPath).sub('/data/', '/data_sequester/')
    return path if File.file? path
  end

  # Not found
  return nil
end

###################################################################################################
# Given a <file> entry in a UCI file, gyrate to obtain the path to the real file on the filesystem.
# Handle old-style paths and sequestered files if necessary.
def pathFromFileMeta(ark, itemDir, fileMeta)
  fileMeta or return nil

  # Prefer to tell the user their original ('native') uploaded file
  fileMeta = fileMeta.at('native') if fileMeta.at('native')

  # Some crazy items don't have a path. Skip them.
  origPath = fileMeta.attr('path')
  origPath or return nil

  # Hack to handle old-style full paths
  partPath = origPath.sub(%r{.*/content/}, '/content/')

  fullPath = "#{itemDir}/#{partPath}"
  if !File.file?(fullPath) && fullPath.include?('/content/') && SubiGuts.isSequestered(ark)
    fullPath.sub! '/data/', '/data_sequester/'
  end

  File.file? fullPath or return nil
  return fullPath
end

###################################################################################################
# Given a <file> entry in a UCI file, gyrate to obtain the just the filename part.
def filenameFromFileMeta(fileMeta)
  fileMeta or return nil

  # Some crazy items don't have a path. Skip them.
  origPath = fileMeta.attr('path')
  if !origPath
    fileMeta = fileMeta.at('native') if fileMeta.at('native')
    origPath = fileMeta.attr('path')
  end
  origPath or return nil

  # Hack to handle old-style full paths
  partPath = origPath.sub(%r{.*/content/}, '/content/')
  return partPath.sub(%r{/?content/}, "")
end

###################################################################################################
def sendNewApprovalEmail(ark, depositorEmail)

  # We need to know the campus(es) of the author(s)
  feedPath = arkToFile(ark, 'meta/base.feed.xml')
  feed = fileToXML(feedPath).remove_namespaces!
  feed = feed.root
  campuses = determineCampuses(feed)

  # Need to find the publication date and title
  meta = fileToXML(arkToFile(ark, 'meta/base.meta.xml'))
  pubDate = meta.text_at('//history/originalPublicationDate')
  title = meta.text_at('title')

  # Calculate the URL for this pub on eScholarship
  url = calcEscholURL(ark, false)

  # On dev and stage, don't send to the real people.
  if !($hostname == 'pub-submit-prd-2a' || $hostname == 'pub-submit-prd-2c')
    depositorEmail = 'kirk.hastings@ucop.edu'
    authorEmail = 'kirk.hastings@ucop.edu'
  end

  sender = 'oa-no-reply@universityofcalifornia.edu'
  recipients = [depositorEmail.strip]

  # Justin would like is to change the email address in the body to match the campus:
  # "it’d be *better* if the email address in the signature wasn’t ours, but idk if
  # you could dynamically insert the campus support address depending upon the
  # depositor’s primary group (?)"

  text = """\
    From: #{sender}
    To: #{recipients.join(', ').sub(%r{^[\s,]+}, '').sub(%r{[\s,]+$}, '')}
    MIME-Version: 1.0
    Content-type: text/html
    Subject: Your article has been successfully deposited in eScholarship

    <html>
      <body>
        <p>Congratulations! This email confirms that you have successfully uploaded a version of your publication
           <b>“#{title}”</b> to eScholarship, UC’s open access repository and publishing platform.
        </p>
        <p>View your publication here: <a href='#{url}'>#{url}</a></p>
        <p>You will receive monthly usage reports for this publication and any others you submit to eScholarship.</p>
        <p>To manage your deposited publications or add additional new ones, return to the
           <a href='http://oapolicy.universityofcalifornia.edu/'>UC Publication Management System</a>,
           a tool developed to support open access policy participation at UC. You can learn more about
           UC’s OA policies at the <a href='http://uc-oa.info'>Office of Scholarly Communication</a>.
        </p>
        <p>Questions? Contact us:
           <a href='mailto:oapolicy-help@universityofcalifornia.edu'>oapolicy-help@universityofcalifornia.edu</a>
        </p>
      </body>
    </html>
    """.unindent

  puts "Sending new approval email:"
  puts text

  begin
    Net::SMTP.start('localhost') do |smtp|
      smtp.send_message(text, sender, recipients.to_a)
    end
  rescue Exception => e
    puts "Warning: unable to send email: #{e}"
  end
end

###################################################################################################
def approveItem(ark, pubID, who=nil, okToEmail=true)

  # Before starting, determine if this is a new item.
  path = arkToFile(ark, 'meta/base.meta.xml', true)
  isNew = !(File.exist? path)

  # Take over ownership of a wacky Elements GUID item, replacing it with Elements pub ID. Changes
  # the arks database so that future scans will correctly scan this item.
  $arkDb.execute("UPDATE arks SET external_id=?, source=?, external_url=? WHERE id=?",
    [pubID, 'elements', nil, ark.sub("ark:/", "ark:")])

  # Most of this is rote
  SubiGuts.approveItem(ark, "Submission completed at oapolicy.universityofcalifornia.edu", who)

  # Jam the data into the eschol5 database, so that immediate API calls will pick it up.
  Bundler.with_clean_env {  # super annoying that bundler by default overrides sub-bundlers environments
    checkCall(["#{$jscholDir}/tools/convert.rb", "--preindex", ark.sub("ark:/13030/", "")])
  }

  # Send email only the first time, and never when we're scanning.
  (isNew && !$scanMode && who && okToEmail) and sendNewApprovalEmail(ark, who)
end

###################################################################################################
def isPublished(ark)

  # For eschol items, check the 'state' attribute in the main metadata
  metaPath = arkToFile(ark, "meta/base.meta.xml")
  File.exists? metaPath or return false
  File.open(metaPath, "r") { |io|
    Nokogiri::XML(io).root.attr('state') == 'published' and return true
  }

  return false
end

###################################################################################################
# Create a 'next' directory for an item, and make it pending there.
def editItem(ark, who=nil, pubID=nil)

  # Skip if the item has never been published.
  return unless File.directory? arkToFile(ark, 'meta')

  # The rest is rote
  SubiGuts.editItem(ark, "Changed on oapolicy.universityofcalifornia.edu", who)
end

###################################################################################################
# Take feed XML from Elements and make a UCI record out of it. Note that if you pass existing UCI
# data in, it will be retained if Elements doesn't override it.
# NOTE: UCI in this context means "UC Ingest" format, the internal metadata format for eScholarship.
# Options: ark, fileVersion
def uciFromFeed(uci, feed, **opt)

  # Parse out the flat list of metadata from the feed
  metaHash = {}
  feed.xpath(".//metadataentry").each { |ent|
    key = ent.text_at('key')
    value = ent.text_at('value')
    if key == 'keywords'
      metaHash[key] ||= []
      metaHash[key] << value
    else
      metaHash.key?(key) and raise("double key #{key}")
      metaHash[key] = value
    end
  }

  # The easy top-level attributes
  if opt[:ark]
    uci[:id] = uci[:id] || opt[:ark].sub(%r{ark:/?13030/}, '')
  end
  ark = uci[:id]
  uci[:dateStamp] = DateTime.now.iso8601
  uci[:peerReview] = uci[:peerReview] || 'yes'
  uci[:state] = uci[:state] || 'new'
  uci[:stateDate] = uci[:stateDate] || DateTime.now.iso8601

  # Figure out the publication ID
  pubID = metaHash.delete('elements-pub-id') or raise("can't find pub ID in feed")

  # Publication type is a bit tricky
  pubTypeStr = metaHash.delete('object.type') or raise("metadata missing object.type")
  uci[:type] = case pubTypeStr
    when %r{^(journal-article|conference-proceeding|internet-publication|scholarly-edition|report)$}; 'paper'
    when %r{^(dataset|poster|media|presentation|other)$}; 'non-textual'
    when "book"; 'monograph'
    when "chapter"; 'chapter'
    else raise "Can't recognize pubType #{pubTypeStr.inspect}" # Happens when Elements changes or adds types
  end

  # Creative Commons license data
  licName = metaHash['requested-reuse-licence.short-name'] || "public"
  rightsEl = uci.find! 'rights'
  rightsEl.content = case licName
    when 'CC BY';       'cc1'
    when 'CC BY-SA';    'cc2'
    when 'CC BY-ND';    'cc3'
    when 'CC BY-NC';    'cc4'
    when 'CC BY-NC-SA'; 'cc5'
    when 'CC BY-NC-ND'; 'cc6'
    when 'public';      'public'
    else; userErrorHalt("Unrecognized reuse license #{licName.inspect}")
  end

  # Author and editor metadata. Use the preferred record if specified.
  transformPeople(uci, metaHash, 'author')
  transformPeople(uci, metaHash, 'editor')

  # Other top-level fields
  uci.find!('source').content = 'oa_harvester'
  metaHash.key?('title') and uci.find!('title').content = metaHash.delete('title')
  metaHash.key?('abstract') and uci.find!('abstract').content = metaHash.delete('abstract')
  metaHash.key?('doi') and uci.find!('doi').content = metaHash.delete('doi')
  if metaHash.key?('fpage') || metaHash.key?('lpage')
    uci.find!('extent').rebuild { |xml|
      metaHash.key?('fpage') and xml.fpage(metaHash.delete('fpage'))
      metaHash.key?('lpage') and xml.lpage(metaHash.delete('lpage'))
    }
  end
  if metaHash.key?('keywords')
    uci.find!('keywords').rebuild { |xml|
      # Transform "1505 Marketing (for)" to just "Marketing"
      metaHash.delete('keywords').map { |kw|
        # Remove scheme at end and initial series of digits
        kw.sub(%r{ \([^)]+\)$}, '').sub(%r{^\d+ }, '')
      }.uniq.each { |kw|
        xml.keyword kw
      }
    }
  end

  # Things that go inside <context>
  contextEl = uci.find! 'context'
  oldEntities = contextEl.xpath(".//entity").dup    # record old entities so we can reconstruct and add to them
  contextEl.rebuild { |xml|
      xml.localID(:type => 'oa_harvester') {
        xml.text pubID
      }
      metaHash.key?("issn") and xml.issn(metaHash.delete("issn"))
      metaHash.key?("isbn-13") and xml.isbn(metaHash.delete("isbn-13")) # for books and chapters
      metaHash.key?("journal") and xml.journal(metaHash.delete("journal"))
      # TODO: deal with proceedings
      metaHash.key?("volume") and xml.volume(metaHash.delete("volume"))
      metaHash.key?("issue") and  xml.issue(metaHash.delete("issue"))
      #metaHash.key?("parent-title") and xml.bookTitle e.text }  # for chapters
      metaHash.key?("oa-location-url") and xml.publishedWebLocation(metaHash.delete("oa-location-url"))
  }

  # Things that go inside <history>
  who = metaHash.delete('depositor-email') or raise("metadata missing depositor-email")
  history = uci.find! 'history'
  history[:origin] = 'oa_harvester'
  history.at("escholPublicationDate") or history.find!('escholPublicationDate').content = Date.today.iso8601
  history.at("submissionDate") or history.find!('submissionDate').content = Date.today.iso8601
  pubDate = metaHash.delete('publication-date') or raise("metadata missing 'date.issued'")
  history.find!('originalPublicationDate').content = case pubDate
    when /^\d\d\d\d-[01]\d-[0123]\d$/; pubDate
    when /^\d\d\d\d-[01]\d$/;          "#{pubDate}-01"
    when /^\d\d\d\d$/;                 "#{pubDate}-01-01"
    else;                              raise("Unrecognized date.issued format: #{pubDate.inspect}")
  end
  if !history.at("stateChange")
    history.build { |xml|
      xml.stateChange(:state => 'new',
                      :date  => DateTime.now.iso8601,
                      :who   => who) {
        xml.comment_ "Deposited at oapolicy.universityofcalifornia.edu"
      }
    }
  end
end

###################################################################################################
def checkForMetaUpdate(pubID, ark, feedMeta, updateTime)

  print "Pub #{pubID} <=> #{ark}: "

  # See if we already have recent data for this entry.
  metaFile = arkToFile(ark, 'next/meta/base.feed.xml')
  File.file?(metaFile) or metaFile = arkToFile(ark, 'meta/base.feed.xml')
  if File.file? metaFile and File.mtime(metaFile).to_datetime > updateTime and not($onlyPub)
    puts "Already updated."
    return
  end

  # If no changes, nothing to do.
  unless isMetaChanged(ark, feedMeta)
    puts "No significant changes."
    return
  end

  # Found changes. Make a 'next' directory if necessary, and save the feed data there.
  # No clear idea who the change should be attributed to, but I see "user" in the feed
  # so let's grab that.
  puts "Changed."

  #who = feedMeta.at("//users/user[1]/email-address").try{|e| e.text.to_s}
  who = nil; puts "TODO: parse who"
  editItem(ark, who, pubID)
  File.open(arkToFile(ark, "next/meta/base.feed.xml", true), "w") { |io| feedMeta.write_xml_to io }

  # Update the UCI metadata for real.
  updateMetadata(ark)

  # If the item has been approved, push this change all the way through.
  #approveItem(ark, who) if isGranted(ark)
end

###################################################################################################
def isMetaChanged(ark, feedData)

  # Read the old metadata
  metaPath = arkToFile(ark, "next/meta/base.meta.xml")
  File.file?(metaPath) or metaPath = arkToFile(ark, "meta/base.meta.xml")
  uci = File.file?(metaPath) ? fileToXML(metaPath) :
        Nokogiri::XML("<uci:record xmlns:uci='http://www.cdlib.org/ucingest'/>")

  # Keep a backup of the old data, then integrate the feed into new metadata
  uciOld = uci.dup
  begin
    uciFromFeed(uci.root, feedData, :ark => ark)
  rescue Exception => e
    puts "Warning: unable to parse feed: #{e}"
    puts e.backtrace
    return false
  end

  # See if there's any significant change
  firstDiff = nil
  equiv = EquivalentXml.equivalent?(uciOld, uci) { |n1, n2, result|
    if result || n1.path =~ /@dateStamp$/
      true
    else
      firstDiff ||= firstDiff = n1.path
      false
    end
  }

  # For diagnostic purposes, if there's a diff say where (in a compact way)
  firstDiff and print "(#{firstDiff.sub('/uci:record/','').sub('/text()','')}) "

  # Meta is changed if it's not equivalent
  return !equiv
end

###################################################################################################
def updateMetadata(ark, fileVersion=nil)

  # Transform the metadata feed to a UCI metadata file.
  feedPath = arkToFile(ark, "next/meta/base.feed.xml")
  feed = fileToXML(feedPath).remove_namespaces!

  metaPathOld = arkToFile(ark, "next/meta/base.meta.xml.old")
  metaPathCur = arkToFile(ark, "next/meta/base.meta.xml")
  metaPathTmp = arkToFile(ark, "next/meta/base.meta.xml.new")

  uci = File.file?(metaPathCur) ? fileToXML(metaPathCur) :
        Nokogiri::XML("<uci:record xmlns:uci='http://www.cdlib.org/ucingest'/>")

  uciFromFeed(uci.root, feed.root, :ark => ark, :fileVersion => fileVersion)
  File.open(metaPathTmp, 'w') { |io| uci.write_xml_to(io, indent:3) }

  # For info, run Jing validation on the result, but don't check the return code.
  cmd = [$java, '-jar', "#{$erepDir}/control/xsl/jing.jar",
         '-c', "#{$erepDir}/schema/uci_schema.rnc",
         metaPathTmp]
  puts "Running jing: '#{cmd.join(" ")}'"
  system(*cmd)

  # Replace the old metadata with the new
  File.rename(metaPathCur, metaPathOld) if File.file? metaPathCur
  File.rename(metaPathTmp, metaPathCur)
  return true

end

###################################################################################################
def transformPeople(uci, metaHash, authOrEd)

  dataBlock = metaHash.delete("#{authOrEd}s") or return

  # Now build the resulting UCI author records.
  uci.find!("#{authOrEd}s").rebuild { |xml|
    person = nil
    dataBlock.split("||").each { |line|
      line =~ %r{\[([-a-z]+)\] ([^|]*)} or raise("can't parse people line #{line.inspect}")
      field, data = $1, $2
      case field
        when 'start-person'
          person = {}
        when 'lastname'
          person[:lname] = data
        when 'firstnames', 'initials'
          if !person[:fname] || person[:fname].size < data.size
            person[:fname] = data
          end
        when 'email-address', 'resolved-user-email'
          person[:email] = data
        when 'resolved-user-orcid'
          person[:orcid] = data
        when 'identifier'
          puts "TODO: Handle identifiers like #{data.inspect}"
        when 'end-person'
          if !person.empty?
            puts "Sending person #{person.inspect}"
            xml.send(authOrEd) {
              person[:fname] and xml.fname(person[:fname])
              person[:lname] and xml.lname(person[:lname])
              person[:email] and xml.email(person[:email])
              person[:orcid] and xml.identifier(:type => 'ORCID') { |xml| xml.text person[:orcid] }
            }
          end
          person = nil
        when 'address'
          # e.g. "University of California, Berkeley\nBerkeley\nUnited States"
          # do nothing with it for now
        else
          raise("Unexpected person field #{field.inspect}")
      end
    }
  }
end
