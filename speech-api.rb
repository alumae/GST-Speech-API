require 'gst'
require 'sinatra'
require 'timeout'
require 'thread'
require 'json'
require 'iconv'
require 'uuidtools'

Gst.init

class Recognizer
	

	def initialize()
		@result = ""
		# construct pipeline
		@pipeline = Gst::Parse.launch("appsrc name=appsrc ! decodebin2 ! audioconvert ! audioresample ! pocketsphinx name=asr ! fakesink")
		
		# define input audio properties
		@appsrc = @pipeline.get_child("appsrc")
		caps = Gst::Caps.parse("audio/x-flac; rate=16000")
		@appsrc.set_property("caps", caps)
		
		# define behaviour for ASR output
		asr = @pipeline.get_child("asr")

		
		@queue = Queue.new
		
		# This returns when ASR engine has been fully loaded
		asr.set_property('configured', true)
		
		asr.signal_connect('partial_result') { |asr, text, uttid| 
			#puts "PARTIAL: " + text 
			@result = text 
		}
		asr.signal_connect('partial_result') { @x }
		asr.signal_connect('result') { |asr, text, uttid| 
			#puts "FINAL: " + text 
			@result = text 	
			@queue.push(1)
		}
		
		#@pipeline.pause
  	end
  	
	# Get current (possibly partial) recognition result
	def result
		@result
	end
  	
  	# Call this before starting a new recognition
  	def clear()
  		@result = ""
  		@queue.clear
  		#@pipeline.pause
  	end
  	
  	# Feed new chunk of audio data to the recognizer
  	def feed_data(data)
  		@pipeline.play  		
		buffer=Gst::Buffer.new
		
	  	buffer.data = data
	  	@appsrc.push_buffer(buffer)
	end
	
	# Notify recognizer of utterance end
	def feed_end()
		@appsrc.end_of_stream()
	end
	
	# Wait for the recognizer to recognize the current utterance
	# Returns the final recognition result
	def wait_final_result()
		@queue.pop
		@appsrc.ready
		return @result
	end
end




configure do
	
	NUM_REC_PROCS = 1
	
	RECOGNIZER_POOL  = Queue.new
	OUTDIR = "out/"
	Gst.init

	set :environment, :development 
	set :raise_errors, true
	set :dump_errors, true
	set :show_exceptions, false
	

	NUM_REC_PROCS.times { 
		rec = Recognizer.new
		RECOGNIZER_POOL.push(rec)
	}

end



post '/recognize' do
	my_rec = nil
	Timeout::timeout(1) do
		puts "getting rec"
		my_rec = RECOGNIZER_POOL.pop()
		puts "got rec"
	end
	begin
		id = SecureRandom.hex
		puts "Request ID: " + id
	    headers "Content-Type" => "application/json; charset=utf-8", "Content-Disposition" => "attachment"
		my_rec.clear()
		puts request.body.size
		buf = request.body.read() 
		File.open(OUTDIR + id +".flac", "wb") { |f|
		    f.write buf
		}
		if buf.length > 0
			my_rec.feed_data(buf)
			my_rec.feed_end()
			result = my_rec.wait_final_result()
			puts result
			
			File.open(OUTDIR + "result.txt", "a") { |f|
				f.write(id + " " + result + "\n")
			}
			result = Iconv.iconv('utf-8', 'latin1', result)
			
			JSON.pretty_generate({:status => 0, :id => id, :hypotheses => [:utterance => result]})
		else
			[500, [], JSON.pretty_generate({:status => 2, :error => "No request content"})]
		end
	rescue
		puts "Error #{$!}"
		puts "Creating new recognizer instance"
		my_rec = Recognizer.new
		[500, [], JSON.pretty_generate({:status => 1, :id => id, :error => $!})]
	ensure 
		RECOGNIZER_POOL.push(my_rec)
	end
end

error Timeout::Error do
	headers "Content-Type" => "application/json; charset=utf-8", "Content-Disposition" => "attachment"
	[503, [], JSON.pretty_generate({:status => 1, :error => "All recognizer instances busy"})]
end

