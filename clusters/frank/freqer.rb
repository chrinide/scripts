#!/usr/bin/env ruby

class Array
  def approx_index value
    @@TOLERANCE=0.001
    index=0
    self.each { |val| 
      break if (value.to_f-val.to_f).abs<@@TOLERANCE
      index+=1
    }
    if index>=self.length then
      return nil
    else
      return index
    end
  end
end

require 'optparse'

$options={}

optparser = OptionParser.new do |opts|
  opts.banner=<<HELPSTR
Usage: freqer.rb [options] [input file]

    By default, file name is 'molecule.log'
    Linear plot will be named as $input_filename.linear_plot.dat and $input_filename.linear_plot.png
    Lorentzian plot will be named as $input_filename.lorentzian_plot.dat and $input_filename.lorentzian_plot.png
HELPSTR

  opts.separator ""

  $options[:quiet]=false
  opts.on('-q','--quiet',"Do not output warnings and general information") do
    $options[:quiet]=true
  end

  $options[:anharmonic]=false
  opts.on('-a','--anharmonic','Parse anharmonic data') do
    $options[:anharmonic]=true
  end

  $options[:linear]=false
  opts.on('-l','--line',"Output linear spectrum") do
    $options[:linear]=true
  end

  $options[:lorentzian]=false
  opts.on('-r','--lorentzian',"Output Lorentzian spectrum") do
    $options[:lorentzian]=true
  end

  $options[:gaussian]=false
  opts.on('-g','--gaussian',"Output Gaussian spectrum") do
    $options[:gaussian]=true
  end

  $options[:bandwidth]=10
  opts.on('-b','--bandwidth BANDWIDTH',"Set the bandwidth") do |bandwidth|
    $options[:bandwidth]=bandwidth.to_i
    raise "Bandwidth need to be positive" if $options[:bandwidth].to_f<0.1
  end

  $options[:csv]=false
  opts.on('-c','--csv',"Output CSV for Excel/OOCalc/LibreCalc") do
    $options[:csv]=true
end

opts.on('-h','--help',"Show help infomration") do
  puts opts
  exit
end

opts.on('-s','--sweep',"Sweep all output files from freqer") do
  print "Sweeping..."
  system "rm -rf sweep >& /dev/null"
  system "mkdir sweep >& /dev/null"
  system "mv *.png sweep >& /dev/null"
  system "mv *.dat sweep >& /dev/null"
  system "mv *.cubic sweep >& /dev/null"
  system "mv *.quartic sweep >& /dev/null"
  system "mv *.csv sweep>& /dev/null"
  system "mv *.tgz sweep>& /dev/null"
  puts "Done."
  exit
end

$options[:pack]=false
opts.on('-p','--pack',"Automatically packs results") do
  $options[:pack]=true
end

opts.separator ""
end

optparser.parse!

$symmetries=Array.new
$frequencies=Array.new
$anharmonic_frequencies=Array.new
$intensities=Array.new
$force_constants=Array.new
#TODO analysis this later
#$cubic_force_constants=Hash.new
#$quartic_force_constants=Hash.new

$input_filename="molecule.log"
$input_filename=ARGV[0] if ARGV[0]!=nil
$basename=File.basename $input_filename
$basename=$basename.split(".")[0]

def harmonic_spectrum input_file
  @@HARMONIC_TRIGGER=/^Harmonic frequencies/
  @@HARMONIC_NEGLECT=3  # neglect 3 lines
  found=false
  harmonic_starter,harmonic_started,harmonic_stat,harmonic_neg=false,false,0,0
  input_file.each do |gauss_line|
    # scan the file for harmonic spectrum
    gauss_line.strip!
    if gauss_line=~@@HARMONIC_TRIGGER then # check trigger
      found=true
      if harmonic_neg!=0 then
        unless $options[:quiet] 
          $stderr.puts "WARNING: More than one spectrum calculation found in Gaussian output file!"
          $stderr.puts "         Anharmonic code might report incorrect results, please check!"
        end
        # insert separators
        $symmetries.push("-")
        $frequencies.push("-")
        $intensities.push("-")
      end
      harmonic_starter,harmonic_neg=true,0
      next
    end
    if harmonic_starter then # check neglected lines
      harmonic_neg+=1
      harmonic_starter,harmonic_started,harmonic_stat=false,true,0 if harmonic_neg==@@HARMONIC_NEGLECT
      next
    end
    if harmonic_started then
      gl_split=gauss_line.split
      if gl_split.size>6 then # atom force term, neglect
        harmonic_stat=0
        next
      elsif gl_split.size==0 then # end of spectrum
        harmonic_starter,harmonic_started,harmonic_neq,harmonic_stat=false,false,0,0
        next
      end
      harmonic_stat+=1
      case harmonic_stat
      when 1 #index
      when 2 #symm
        $symmetries.push(gl_split)
      when 3 #freq
        $frequencies.push(gl_split.drop(2))
      when 4 #red. mass
      when 5 #force constant
        $force_constants.push(gl_split.drop(3))
      when 6 #intensity
        $intensities.push(gl_split.drop(3))
      else # ????
        $stderr.puts "???=#{harmonic_stat} line=#{gauss_line}"
      end
    end # if harmonic_started
  end # input_file.each
  $symmetries.flatten!
  $frequencies.flatten!
  $intensities.flatten!
  $force_constants.flatten!

  return found
end

def anharmonic_spectrum input_file
  @@ANHARMONIC_TRIGGER=/^Vibrational Energies/
  @@ANHARMONIC_STARTER=/^Fundamental Bands/
  @@ANHARMONIC_ENDER=/^Overtones/
  anharmonic_starter,anharmonic_started=false,false
  anharmonic_found=false
  input_file.each do |gauss_line|
    gauss_line.strip!
    if gauss_line=~@@ANHARMONIC_STARTER then
      anharmonic_starter=true
      anharmonic_found=true
      next
    end
    if anharmonic_starter then
      if gauss_line=~@@ANHARMONIC_ENDER then
        anharmonic_starter=false
        next
      end
      gl_split=gauss_line.split
      old_freq=gl_split[1]
      new_freq=gl_split[2]
      index=$frequencies.approx_index old_freq
      if new_freq.to_f-old_freq.to_f>0 then
        unless $options[:quiet]
          $stderr.puts "WARNING: Anharmonic frequency has a positive shift!"
          $stderr.puts "    LINE: #{gauss_line}"
        end
      end
      if index==nil then # corresponding harmonic index not found
        unless $options[:quiet]
          $stderr.puts "WARNING: Cannot found harmonic frequency corresponding to anharmonic frequency #{new_freq}"
        end
      else
        $anharmonic_frequencies[index]=new_freq
      end
    end # if anharmonic_starter
  end # input_file.each

  unless anharmonic_found
    $stderr.puts "WARNING: Anharmonic frequencies not found!" unless $options[:quiet]
  end
end

def anharmonic_force_constants input_file
  # collect the cubic and quartic force constants
  @@CUBIC_TRIGGER=/CUBIC FORCE CONSTANTS IN NORMAL MODES/
  @@QUARTIC_TRIGGER=/QUARTIC FORCE CONSTANTS IN NORMAL MODES/
  @@CONSTANT_STARTER=/\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\./
  @@CONSTANT_ENDER=/derivatives larger/
  cubic_starter,cubic_started,quartic_starter,quartic_started=false,false,false,false
  cubic_found,quartic_found=false,false

  cubic_output=File.new "#{$basename}.cubic","w+"
  quartic_output=File.new "#{$basename}.quartic","w+"
  cubic_csv_output=File.new "#{$basename}.cubic.csv","w+" if $options[:csv]
  quartic_csv_output=File.new "#{$basename}.quartic.csv","w+" if $options[:csv]

  input_file.each do |gauss_line|
    gauss_line.strip!

    next if gauss_line.size==0  # neglect empty lines

    if gauss_line=~@@CUBIC_TRIGGER then
      cubic_starter=true
      cubic_found=true
      next
    end

    if gauss_line=~@@QUARTIC_TRIGGER then
      quartic_starter=true
      quartic_found=true
      next
    end

    if gauss_line=~@@CONSTANT_ENDER
      cubic_starter,cubic_started,quartic_starter,quartic_started=false,false,false,false
    end

    if cubic_starter then
      if cubic_started then
        gl_split=gauss_line.split
        if gl_split[0]=="I" then
          # write the headers
          cubic_output.puts "#\tI\tJ\tK\tdE(cm-1)\tk(Hartree*amu(-2)*Bohr(-4)"
          cubic_csv_output.puts "I,J,K,dE(cm-1},k(Hartree*amu(-2)*Bohr(-4)" if $options[:csv]
          next
        else
          cubic_output.puts "#{gl_split[0]}\t#{gl_split[1]}\t#{gl_split[2]}\t#{gl_split[3]}\t#{gl_split[5]}"
          cubic_csv_output.puts "#{gl_split[0]},#{gl_split[1]},#{gl_split[2]},#{gl_split[3]},#{gl_split[5]}" if $options[:csv]
        end
      else #cubic_started
        if gauss_line=~@@CONSTANT_STARTER
          cubic_started=true
          next
        end
      end
    elsif quartic_starter then
      if quartic_started then
        gl_split=gauss_line.split
        if gl_split[0]=="I" then
          # write the headers
          quartic_output.puts "#\tI\tJ\tK\tL\tdE(cm-1)\tk(Hartree*amu(-2)*Bohr(-4)"
          quartic_csv_output.puts "I,J,K,L,dE(cm-1),k(Hartree*amu(-2)*Bohr(-4)" if $options[:csv]
          next
        else
          quartic_output.puts "#{gl_split[0]}\t#{gl_split[1]}\t#{gl_split[2]}\t#{gl_split[3]}\t#{gl_split[4]}\t#{gl_split[6]}"
          quartic_csv_output.puts "#{gl_split[0]},#{gl_split[1]},#{gl_split[2]},#{gl_split[3]},#{gl_split[4]},#{gl_split[6]}" if $options[:csv]
        end
      else #quartic_started
        if gauss_line=~@@CONSTANT_STARTER
          quartic_started=true
          next
        end
      end
    end
  end

  cubic_output.close
  quartic_output.close
  cubic_csv_output.close if cubic_csv_output!=nil
  quartic_csv_output.close if quartic_csv_output!=nil
end

# read the Gaussian output file
input=File.new($input_filename,"r+")
raise "Harmonic spectrum not found!" if not harmonic_spectrum input
input.rewind
if $options[:anharmonic]
  $anharmonic_frequencies=Array.new $frequencies.length 
  anharmonic_spectrum input
  input.rewind
  anharmonic_force_constants input
end

# output the peaks 
unless $options[:quiet]
  0.upto($symmetries.size-1) do |index|
    puts "i-#{index+1}\ts-#{$symmetries[index]}\tf-#{$frequencies[index]}\ta-#{$anharmonic_frequencies[index]}\tt-#{$intensities[index]}\tfc-#{$force_constants[index]}"
  end
end

$image_y_scale=0.0

def reevaluate_y_scale
  max=0
  $intensities.each { |val| max=val.to_f if max<val.to_f }
  $image_y_scale=max+300 
end

$image_x_min=0
$image_x_max=0

def reevaluate_x_scale
  max,min=0,4000

  # check harmonic x range
  $frequencies.each { |val|
    max=val.to_f if max<val.to_f
    min=val.to_f if min>val.to_f
  }

  # check anharmonic x range
  if $anharmonic_frequencies.size!=0 then
    $anharmonic_frequencies.each { |val|
      max=val.to_f if max<val.to_f
      min=val.to_f if min>val.to_f
    }
  end

  min-=50
  max+=50
  min=min.to_i
  max=max.to_i

  min=0 if min>0
  max=3500 if max<3500
  $image_x_min=min
  $image_x_max=max
end

def linear_plot
  output_pngname="#{$basename}.linear_plot.png"
  output_datname="#{$basename}.linear_plot.dat"
  output_csvname="#{$basename}.linear_plot.csv"

  # TODO current only draw the first spectrum
  datfile=File.new output_datname,"w+"
  datfile.print "# Index\t\tSymmetry\t\tHarmonic"
  datfile.print "\t\tAnharmonic" if $options[:anharmonic]
  datfile.print "\t\tIntensity\t\tForce Constants\n"

  datfile_csv=nil
  if $options[:csv] then
    datfile_csv=File.new output_csvname,"w+"
    datfile_csv.print "Index,Symmetry,Harmonic"
    datfile_csv.print ",Anharmonic" if $options[:anharmonic]
    datfile_csv.print ",Intensity,Force Constants\n"
  end

  0.upto($symmetries.size-1) do |index|
    if $symmetries[index]=='-' then
      $stderr.puts "Currently only the first spectrum is outputed."
      exit
    end
    datfile.print format("  %3d\t\t%-5s\t\t  %15.4f",index.to_i,$symmetries[index],$frequencies[index].to_f)
    datfile.print format("\t%15.3f",$anharmonic_frequencies[index]) if $options[:anharmonic]
    datfile.print format("\t\t%15.4f\t%15.4f\n",$intensities[index],$force_constants[index])

    if $options[:csv] then
      datfile_csv.print "#{index+1},#{$symmetries[index]},#{$frequencies[index]}"
      datfile_csv.print ",#{$anharmonic_frequencies[index]}" if $options[:anharmonic]
      datfile_csv.print ",#{$intensities[index]},#{$force_constants[index]}\n"
    end
  end 
  datfile.close
  datfile_csv.close unless datfile_csv.nil?

  intensity_col=4
  intensity_col=5 if $options[:anharmonic]
  # Do the plotting
  gnuplot=IO.popen "gnuplot","w+"
  gnuplot.puts "set term png size 800,800"
  gnuplot.puts "set output '#{output_pngname}'"
  gnuplot.puts "set key left top"
  gnuplot.puts "set yrange [0:#{$image_y_scale}]"
  gnuplot.puts "set xrange [#{$image_x_min}:#{$image_x_max}]"
  gnuplot.puts "plot '#{output_datname}' using 3:#{intensity_col} with impulses title 'Harmonic'"
  gnuplot.puts "exit"
  gnuplot.close
  gnuplot=nil

  # Plot the anharmonic spectrums
  if $options[:anharmonic] then
    output_pngname1="#{$basename}.anharmonic.linear_plot.png"
    gnuplot=IO.popen "gnuplot","w+"
    gnuplot.puts "set term png size 800,800"
    gnuplot.puts "set output '#{output_pngname1}'"
    gnuplot.puts "set key left top"
    gnuplot.puts "set yrange [0:#{$image_y_scale}]"
    gnuplot.puts "set xrange [#{$image_x_min}:#{$image_x_max}]"
    gnuplot.puts "plot '#{output_datname}' using 4:#{intensity_col} with impulses title 'Anharmonic'"
    gnuplot.puts "exit"
    gnuplot.close
    gnuplot=nil

    # Plot two spectrums together
    output_pngname2="#{$basename}.mix.linear_plot.png"
    gnuplot=IO.popen "gnuplot","w+"
    gnuplot.puts "set term png size 800,800"
    gnuplot.puts "set output '#{output_pngname2}'"
    gnuplot.puts "set key left top"
    gnuplot.puts "set yrange [0:#{$image_y_scale}]"
    gnuplot.puts "set xrange [#{$image_x_min}:#{$image_x_max}]"
    gnuplot.puts "plot '#{output_datname}' using 3:#{intensity_col} with impulses title 'Harmonic','' using 4:#{intensity_col} with impulses title 'Anharmonic'"
    gnuplot.puts "exit"
    gnuplot.close
    gnuplot=nil
  end
end

def func_plot name,gnuplot,freq,title
  @@WALK_STEP=1.0

  output_pngname="#{$basename}.#{name}.png"
  output_datname="#{$basename}.#{name}.dat"

  plot={}
  $image_x_min.step($image_x_max,@@WALK_STEP) { |index| plot[index]=0.0 }
  index=0
  freq.each { |term| 
    val=term.to_f
    $image_x_min.step($image_x_max,@@WALK_STEP) { |x|
      plot[x]+=yield $intensities[index].to_f,val,x
    }
    index+=1
  }

  output_tmp=File.new "#{output_datname}","w+"
  output_tmp.puts "# cm-1\t\tintensity"
  $image_x_min.step($image_x_max,@@WALK_STEP) { |index|
    output_tmp.puts "#{index}\t\t#{plot[index]}"
  }
  output_tmp.close

  gnuplot.puts "set terminal png size 800,800"
  gnuplot.puts "set output '#{output_pngname}'"
  gnuplot.puts "set key left top"
  gnuplot.puts "set yrange [0:#{$image_y_scale}]"
  gnuplot.puts "set xrange [#{$image_x_min}:#{$image_x_max}]"
  gnuplot.puts "plot '#{output_datname}' w l title '#{title}'"
end

def lorentzian_plot
  print "Preparing Lorentzian plot, it will take some time..." unless $options[:quiet]
  gnuplot=IO.popen "gnuplot","w+"
  func_plot("lorentzian",gnuplot,$frequencies,"Harmonic"){ |inten,val,x|
    inten*(0.5*$options[:bandwidth])**2/((x-val)**2+(0.5*$options[:bandwidth])**2)
  }

  func_plot("anharmonic.lorentzian",gnuplot,$anharmonic_frequencies,"Anharmonic") { |inten,val,x|
    inten*(0.5*$options[:bandwidth])**2/((x-val)**2+(0.5*$options[:bandwidth])**2)
  }
  gnuplot.close
  gnuplot=nil
  puts "Done!" unless $options[:quiet]
end

def gaussian_plot
  print "Preparing Gaussian plot, it will take some time..." unless $options[:quiet]
  gnuplot=IO.popen "gnuplot","w+"
  func_plot("gaussian",gnuplot,$frequencies,"Harmonic"){ |inten,val,x|
    #inten*(1.0/(Math.sqrt(2*Math::PI)*$options[:bandwidth]))*Math.exp(-(x-val)**2/(2*$options[:bandwidth]**2))
    inten*Math.exp(-(x-val)**2/(2*$options[:bandwidth]**2))
  }

  func_plot("anharmonic.gaussian",gnuplot,$anharmonic_frequencies,"Anharmonic") { |inten,val,x|
    inten*Math.exp(-(x-val)**2/(2*$options[:bandwidth]**2))
  }
  gnuplot.close
  gnuplot=nil
  puts "Done!" unless $options[:quiet]
end

# write the temporary file for plotting
reevaluate_y_scale
reevaluate_x_scale
linear_plot if $options[:linear]
lorentzian_plot if $options[:lorentzian]
gaussian_plot if $options[:gaussian]


def pack_outputs
  print "Packing outputs..." unless $options[:quiet]
  system "tar czf #{$basename}.tgz *.png *.dat #{$input_filename} #{$basename}.cubic #{$basename}.quartic *.csv >& /dev/null"
  puts "Done." unless $options[:quiet]
end

pack_outputs if $options[:pack]
