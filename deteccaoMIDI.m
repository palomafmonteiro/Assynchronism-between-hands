clear all
close all
clc

transcricao = fopen("01-241020_1534 Paloma dia 20 de Out. Exp.1-1st.MID");


[data,byteCount] = fread(transcricao);
fclose(transcricao);

% Concatenate ticksPerQNote from 2 bytes
ticksPerQNote = polyval(data(13:14),256);

% Initialize values
chunkIndex = 14;     % Header chunk is always 14 bytes
ts = 0;              % Timestamp - Starts at zero
BPM = 120;                  
msgArray = [];              

% Parse track chunks in outer loop
while chunkIndex < byteCount
    
    % Read header of track chunk, find chunk length   
    % Add 8 to chunk length to account for track chunk header length
    chunkLength = polyval(data(chunkIndex+(5:8)),256)+8;
    
    ptr = 8+chunkIndex;             % Determine start for MIDI event parsing
    statusByte = -1;                % Initialize statusByte. Used for running status support
    
    % Parse MIDI track events in inner loop
    while ptr < chunkIndex+chunkLength
        % Read delta-time
        [deltaTime,deltaLen] = findVariableLength(ptr,data);  
        % Push pointer to beginning of MIDI message
        ptr = ptr+deltaLen;
        
        % Read MIDI message
        [statusByte,messageLen,message] = interpretMessage(statusByte,ptr,data);
        % Extract relevant data - Create midimsg object
        [ts,msg] = createMessage(message,ts,deltaTime,ticksPerQNote,BPM);
        
        % Add midimsg to msgArray
        msgArray = [msgArray;msg];
        % Push pointer to next MIDI message
        ptr = ptr+messageLen;
    end
    
    % Push chunkIndex to next track chunk
    chunkIndex = chunkIndex+chunkLength;
end
disp(msgArray)



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

datasize = length(msgArray)-1;
aux = 1;
for i=1:datasize
    if (msgArray(i).Velocity ~= 0)
        asynchronytable(aux,1)= msgArray(i).Note;
        asynchronytable(aux,2)= msgArray(i).Velocity;
        asynchronytable(aux,3)= msgArray(i).Timestamp;
        aux = aux+1;
    end
end
asynchronytable = num2cell(asynchronytable);
for i=1:length(asynchronytable)
    asynchronytable{i,1} = midi2note(asynchronytable{i,1});
end

% Convert cell array to table
T = cell2table(asynchronytable);
filename = 'asyncvel.csv';
writetable(T, filename);% Write table to CSV file

numPairs = floor(length(asynchronytable)/2);
asyncdiff = cell(numPairs, 2);
aux = 1;
for i = 1:2:(numPairs*2)
    asyncdiff{aux,1} = strcat(asynchronytable{i,1}, '->', asynchronytable{i+1,1});
    asyncdiff{aux,2} = asynchronytable{i+1,3} - asynchronytable{i,3};
    aux = aux+1;
end


% Convert cell array to table
T2 = cell2table(asyncdiff);
filename2 = 'asyncdiff.csv';
writetable(T2, filename2);% Write table to CSV file


function nota = midi2note(midi_number)
    % Mapeamento das notas musicais
    notas = {'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'};
    % Calcula a nota e a oitava
    note_index = mod(midi_number, 12) + 1; % +1 porque o MATLAB usa índices de 1 a 12
    octave = floor(midi_number / 12) - 1;
    % Obtém o nome completo da nota musical
    nota = [notas{note_index} num2str(octave)];
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [valueOut,byteLength] = findVariableLength(lengthIndex,readOut)

byteStream = zeros(4,1);

for i = 1:4
    valCheck = readOut(lengthIndex+i);
    byteStream(i) = bitand(valCheck,127);   % Mask MSB for value
    if ~bitand(valCheck,uint32(128))        % If MSB is 0, no need to append further
        break
    end
end

valueOut = polyval(byteStream(1:i),128);    % Base is 128 because 7 bits are used for value
byteLength = i;

end


function [statusOut,lenOut,message] = interpretMessage(statusIn,eventIn,readOut)

% Check if running status
introValue = readOut(eventIn+1);
if isStatusByte(introValue)
    statusOut = introValue;         % New status
    running = false;
else
    statusOut = statusIn;           % Running status—Keep old status
    running = true;
end

switch statusOut
    case 255     % Meta-event (FF)—IGNORE
        [eventLength, lengthLen] = findVariableLength(eventIn+2, ...
            readOut);   % Meta-events have an extra byte for type of meta-event
        lenOut = 2+lengthLen+eventLength;
        message = -1;
    case 240     % Sysex message (F0)—IGNORE
        [eventLength, lengthLen] = findVariableLength(eventIn+1, ...
            readOut);
        lenOut = 1+lengthLen+eventLength;
        message = -1;
        
    case 247     % Sysex message (F7)—IGNORE
        [eventLength, lengthLen] = findVariableLength(eventIn+1, ...
            readOut);
        lenOut = 1+lengthLen+eventLength;
        message = -1;
    otherwise    % MIDI message—READ
        eventLength = msgnbytes(statusOut);
        if running  
            % Running msgs don't retransmit status—Drop a bit
            lenOut = eventLength-1;
            message = uint8([statusOut;readOut(eventIn+(1:lenOut))]);
            
        else
            lenOut = eventLength;
            message = uint8(readOut(eventIn+(1:lenOut)));
        end
end

end

% ----

function n = msgnbytes(statusByte)

if statusByte <= 191        % hex2dec('BF')
    n = 3;
elseif statusByte <= 223    % hex2dec('DF')
    n = 2;
elseif statusByte <= 239    % hex2dec('EF')
    n = 3;
elseif statusByte == 240    % hex2dec('F0')
    n = 1;
elseif statusByte == 241    % hex2dec('F1')
    n = 2;
elseif statusByte == 242    % hex2dec('F2')
    n = 3;
elseif statusByte <= 243    % hex2dec('F3')
    n = 2;
else
    n = 1;
end

end

% ----

function yes = isStatusByte(b)
yes = b > 127;
end


function [tsOut,msgOut] = createMessage(messageIn,tsIn,deltaTimeIn,ticksPerQNoteIn,bpmIn)

if messageIn < 0     % Ignore Sysex message/meta-event data
    tsOut = tsIn;
    msgOut = midimsg(0);
    return
end

% Create RawBytes field
messageLength = length(messageIn);
zeroAppend = zeros(8-messageLength,1);
bytesIn = transpose([messageIn;zeroAppend]);

% deltaTimeIn and ticksPerQNoteIn are both uints
% Recast both values as doubles
d = double(deltaTimeIn);
t = double(ticksPerQNoteIn);

% Create Timestamp field and tsOut
msPerQNote = 6e7/bpmIn;
timeAdd = d*(msPerQNote/t)/1e6;
tsOut = tsIn+timeAdd;

% Create midimsg object
midiStruct = struct('RawBytes',bytesIn,'Timestamp',tsOut);
msgOut = midimsg.fromStruct(midiStruct);

end
