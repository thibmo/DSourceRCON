{
  Copyright 2018 Thimo Braker <thibmorozier@live.nl>

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
}
{
Source RCON Packet Structure:
  Field        Type                           Value
  Size         Little-endian Signed Int32     Varies
  ID           Little-endian Signed Int32     Varies
  Type         Little-endian Signed Int32     Varies
  Body         Null-terminated ASCII String   Varies, max 4086 long (*
                                                10(!) bits bave been reserved.
                                                See below why.
                                              *)
  Terminator   Null-terminated ASCII String   #$00

Packet Size:
  Packet size is calculated based on the following values:
    - SizeOf(ID)       = 4
    - SizeOf(Type)     = 4
    - Length(Body) + 1 = At least 1
    - Terminator       = 1

  The minimum possible value for packet size is 10, the maximum possible value
  of packet size is 4096. Since the only value that can change in length is the
  body, an easy way to calculate the size of a packet is to find the byte-length
  of the packet body, then add 10 to it.

Packet ID:
  A free to choose ID. If unique values are used, incoming packets can be
  matched to their corresponding request, this is always true unless it's a
  failed SERVERDATA_AUTH_RESPONSE packet, then it's -1.

Packet Type:
  An indicator for the purpose of the packet. It's value will always be either
  0, 2, or 3, depending on which of the following request/response types the
  packet represents:
    - SERVERDATA_AUTH           = 3
    - SERVERDATA_AUTH_RESPONSE  = 2
    - SERVERDATA_EXECCOMMAND    = 2
    - SERVERDATA_RESPONSE_VALUE = 0

Packet Body:
  A string of ANSI chars, terminated by a null-byte (#0 or #$00)

Packet Terminator:
  A single NULL-byte (#0 or #$00)
}
unit DSourceRCON;

interface
uses
  Classes, SysUtils, AnsiStrings, Math,
  OverbyteIcsWSocket,
  DByteArrayCompat;

const
  RCON_HEADER_SIZE      = 10;
  REAL_RCON_HEADER_SIZE = 14;
  MAX_PACKET_SIZE       = 16400; // ~16 Kbit, 4 packets

type
  TRCONPacketType = (
    SERVERDATA_RESPONSE_VALUE = 0,
    SERVERDATA_AUTH_RESPONSE  = 2,
    SERVERDATA_EXECCOMMAND    = 2,
    SERVERDATA_AUTH           = 3
  );

  TIPEndPoint = record
    Host: string;
    Port: Word;
  end;
  TRCONPacket = record
    DataSize:   Cardinal;
    RequestId:  Integer;
    PacketType: TRCONPacketType;
    Data:       AnsiString;
  end;

  TMessageNotifyEvent = procedure(aMessage: string) of object;
  TPacketNotifyEvent  = procedure(aPacket: TRCONPacket) of object;

  TSourceRCON = class(TObject)
  strict private
    const
      MARKER_SIZE: Byte = 0;
      MARKER_ID:   Byte = 4;
      MARKER_TYPE: Byte = 8;
      MARKER_DATA: Byte = 12;
    var
      fSocket:          TWSocket;
      fDisconnectEvent: TNotifyEvent;
      fErrorEvent:      TMessageNotifyEvent;
      fSentEvent,
      fReplyEvent:      TPacketNotifyEvent;
      fDataQueue:       TBytes;
      fDataQueueLength: Integer;
      fPassword:        string;
      fSendNullPacket:  Boolean;
      fTempPacket:      TRCONPacket;
    procedure SendRCONPacket(aPacket: TRCONPacket);
    procedure Connected(Sender: TObject; ErrCode: Word);
    procedure Disconnected(Sender: TObject; ErrCode: Word);
    procedure DataAvailable(Sender: TObject; ErrCode: Word);
    procedure ProcessData(aData: Pointer; aLength: Integer);
    function IsSRCDSMirrorPacket: Integer;
    procedure TriggerDisconnectEvent(aSender: TObject);
    procedure TriggerErrorEvent(aMessage: string);
    procedure TriggerSentEvent(aPacket: TRCONPacket);
    procedure TriggerReplyEvent(aPacket: TRCONPacket);
  public
    constructor Create(aSendNullPacket: Boolean = True);
    destructor Destroy; override;
    function Connect(aEndpoint: TIPEndPoint; aPassword: string): Boolean;
    procedure Disconnect;
    procedure ServerCommand(aCommand: string);
    property OnDisconnect:   TNotifyEvent        read fDisconnectEvent write fDisconnectEvent;
    property OnError:        TMessageNotifyEvent read fErrorEvent      write fErrorEvent;
    property OnSent:         TPacketNotifyEvent  read fSentEvent       write fSentEvent;
    property OnReply:        TPacketNotifyEvent  read fReplyEvent      write fReplyEvent;
    property SendNullPacket: Boolean             read fSendNullPacket  write fSendNullPacket;
  end;

function LazyPacketTypeToString(aType: TRCONPacketType): string;

implementation

{ TSourceRCON }
constructor TSourceRCON.Create(aSendNullPacket: Boolean = True);
begin
  SetLength(fDataQueue, 0);
  fDataQueueLength := 0;
  fSendNullPacket  := aSendNullPacket;
end;

destructor TSourceRCON.Destroy;
begin
  if fSocket <> nil then
  begin
    fSocket.Close;
    Sleep(10);
    FreeAndNil(fSocket);
  end;
end;

function TSourceRCON.Connect(aEndpoint: TIPEndPoint; aPassword: string): Boolean;
begin
  if fSocket <> nil then
  begin
    Result := False;
    Exit;
  end;

  Randomize;
  Result    := True;
  fPassword := aPassword;
  SetLength(fDataQueue, 0);
  fDataQueueLength       := 0;
  fTempPacket.DataSize   := 0;
  fTempPacket.RequestId  := 0;
  fTempPacket.PacketType := SERVERDATA_RESPONSE_VALUE;
  fTempPacket.Data       := EmptyAnsiStr;

  fSocket                    := TWSocket.Create(nil);
  fSocket.ComponentOptions   := [wsoTcpNoDelay];
  fSocket.Proto              := 'tcp';
  fSocket.Addr               := aEndpoint.Host;
  fSocket.Port               := IntToStr(aEndpoint.Port);
  fSocket.OnSessionConnected := Connected;
  fSocket.OnSessionClosed    := Disconnected;
  fSocket.OnDataAvailable    := DataAvailable;

  try
    fSocket.Connect;
  except
    on E : Exception do
    begin
      Result := False;

      if Assigned(fErrorEvent) then
      begin
        FreeAndNil(fSocket);
        TriggerErrorEvent(E.Message);
        Exit;
      end else
        raise;
    end;
  end;
end;

procedure TSourceRCON.Disconnect;
begin
  if fSocket <> nil then
    fSocket.Close;

  SetLength(fDataQueue, 0);
  fDataQueueLength := 0;
end;

procedure TSourceRCON.ServerCommand(aCommand: string);
var
  Packet,
  HackPack: TRCONPacket;
  TmpStr:   AnsiString;
begin
  TmpStr            := AnsiString(aCommand);
  Packet.DataSize   := Length(TmpStr);
  Packet.RequestId  := RandomRange(2, 4096);
  Packet.PacketType := SERVERDATA_EXECCOMMAND;
  Packet.Data       := TmpStr;
  SendRCONPacket(Packet);

  if fSendNullPacket then
  begin
    HackPack.DataSize   := 0;
    HackPack.RequestId  := RandomRange(2, 4096);
    HackPack.PacketType := SERVERDATA_RESPONSE_VALUE;
    HackPack.Data       := EmptyAnsiStr;
    SendRCONPacket(HackPack);
  end;

  TriggerSentEvent(Packet);
end;

procedure TSourceRCON.SendRCONPacket(aPacket: TRCONPacket);
var
  Buff: Pointer;
  Len:  Cardinal;
begin
  if fSocket.State = wsConnected then
  begin
    // Data is prefixed by 3 Int32s and suffixed with 2 null-bytes
    Len := aPacket.DataSize + REAL_RCON_HEADER_SIZE;
    GetMem(Buff, Len);

    PInteger(Cardinal(Buff) + MARKER_SIZE)^ := aPacket.DataSize + RCON_HEADER_SIZE;
    PInteger(Cardinal(Buff) + MARKER_ID)^   := aPacket.RequestId;
    PInteger(Cardinal(Buff) + MARKER_TYPE)^ := Integer(aPacket.PacketType);

    if Len > REAL_RCON_HEADER_SIZE then
    begin

      Move(
        TByteConverter.GetBytes(aPacket.Data)[0],
        Pointer(cardinal(Buff) + MARKER_DATA)^,
        aPacket.DataSize
      );
    end;

    PWord(Cardinal(Buff) + (Len - 2))^ := 0;
    fSocket.Send(Buff, Len);
    FreeMem(Buff);
  end;
end;

procedure TSourceRCON.Connected(Sender: TObject; ErrCode: Word);
var
  Packet: TRCONPacket;
  TmpStr: AnsiString;
begin
  if ErrCode <> 0 then
    TriggerErrorEvent('Error while trying to connect to socket: ' + WSocketErrorDesc(ErrCode))
  else
  begin
    fSocket.SetTcpNoDelayOption;
    fSocket.SocketSndBufSize := 65536; // 64Kb
    fSocket.BufSize          := 32768; // 32Kb
  end;

  TmpStr            := AnsiString(fPassword);
  Packet.DataSize   := Length(TmpStr);
  Packet.RequestId  := 1; // Let's have auth as 1 so it's always unique
  Packet.PacketType := SERVERDATA_AUTH;
  Packet.Data       := TmpStr;
  SendRCONPacket(Packet);
  TriggerSentEvent(Packet);
end;

procedure TSourceRCON.Disconnected(Sender: TObject; ErrCode: Word);
begin
  if ErrCode <> 0 then
    TriggerErrorEvent('Disconnection error: ' + WSocketErrorDesc(ErrCode));

  TriggerDisconnectEvent(self);
end;

procedure TSourceRCON.DataAvailable(Sender: TObject; ErrCode: Word);
var
  Count: Integer;
  Buff:  Pointer;
begin
  if ErrCode <> 0 then
  begin
    TriggerErrorEvent('Socket error: ' + WSocketErrorDesc(ErrCode));
    Exit;
  end;

  Sleep(100); // Wait a bit to be sure we have everything
  GetMem(Buff, MAX_PACKET_SIZE + 1);
  Count := TWSocket(Sender).Receive(Buff, MAX_PACKET_SIZE);

  if Count > 0 then
    ProcessData(Buff, Count);

  FreeMem(Buff);
end;

procedure TSourceRCON.ProcessData(aData: Pointer; aLength: Integer);
var
  Packet:       TRCONPacket;
  PacketLength: Integer;
begin
  SetLength(fDataQueue, fDataQueueLength + aLength);
  Move(aData^, fDataQueue[fDataQueueLength], aLength);
  Inc(fDataQueueLength, aLength);

  while fDataQueueLength > 0 do
  begin
    PacketLength := IsSRCDSMirrorPacket;

    if (PacketLength = 0) and (fDataQueueLength >= REAL_RCON_HEADER_SIZE) then
    begin
      Packet.DataSize   := PInteger(@fDataQueue[MARKER_SIZE])^ - RCON_HEADER_SIZE;
      Packet.RequestId  := PInteger(@fDataQueue[MARKER_ID])^;
      Packet.PacketType := TRCONPacketType(PInteger(@fDataQueue[MARKER_TYPE])^);
      PacketLength      := Packet.DataSize + REAL_RCON_HEADER_SIZE;

      if Packet.DataSize > 0 then
      begin
        Packet.Data := AnsiStrings.StringReplace(
          TByteConverter.ToAnsiStr(
            fDataQueue,
            MARKER_DATA,
            Packet.DataSize
          ),
          #$A,
          sLineBreak,
          [rfReplaceAll]
        );
      end else
        Packet.Data := '';

      TriggerReplyEvent(Packet);
    end;

    Assert(PacketLength <= fDataQueueLength, 'PacketLength is greater then fDataQueueLength');
    // Trim buffer
    fDataQueue := Copy(fDataQueue, PacketLength, Length(fDataQueue) - PacketLength);
    Dec(fDataQueueLength, PacketLength);
  end;
end;

function TSourceRCON.IsSRCDSMirrorPacket: Integer;
begin
  {
    Error packets may be either one of the following formats:
      - 01 00 00 0
      - 00 01 00 00
  }
  if (fDataQueue[0] = 0) and (fDataQueue[1] = 1) and
     (fDataQueue[2] = 0) and (fDataQueue[3] = 0) and
     (fDataQueue[4] = 0) and (fDataQueue[5] = 0) and
     (fDataQueue[6] = 0) then
    Result := 7
  else if (fDataQueue[0] = 0) and (fDataQueue[1] = 0) and
          (fDataQueue[2] = 0) and (fDataQueue[3] = 1) and
          (fDataQueue[4] = 0) and (fDataQueue[5] = 0) and
          (fDataQueue[6] = 0) and (fDataQueue[7] = 0) then
    Result := 8
  else
    Result := 0;
end;

procedure TSourceRCON.TriggerDisconnectEvent(aSender: TObject);
begin
  Assert(Assigned(fDisconnectEvent), 'Disconnect event SHOULD ALWAYS be assigned.');
  fDisconnectEvent(aSender);
end;

procedure TSourceRCON.TriggerErrorEvent(aMessage: string);
begin
  if Assigned(fErrorEvent) then
    fErrorEvent(aMessage);
end;

procedure TSourceRCON.TriggerSentEvent(aPacket: TRCONPacket);
begin
  if Assigned(fSentEvent) then
    fSentEvent(aPacket);
end;

{
  If we sent a NullPacket we help the lib user, by collecting data packets until
  the ID changes.
}
procedure TSourceRCON.TriggerReplyEvent(aPacket: TRCONPacket);
begin
  Assert(Assigned(fReplyEvent), 'Reply event SHOULD ALWAYS be assigned.');

  if (aPacket.PacketType = SERVERDATA_AUTH_RESPONSE) or not fSendNullPacket then
  begin
    fReplyEvent(aPacket);
  end else
  begin
    if fTempPacket.DataSize = 0 then
      fTempPacket := aPacket
    else if fTempPacket.RequestId <> aPacket.RequestId then
    begin
      fReplyEvent(fTempPacket);
      fTempPacket := aPacket;
    end else
    begin
      Inc(fTempPacket.DataSize, aPacket.DataSize);
      fTempPacket.Data := fTempPacket.Data + aPacket.Data;
    end;
  end;
end;

function LazyPacketTypeToString(aType: TRCONPacketType): string;
begin
  if aType = SERVERDATA_RESPONSE_VALUE then
    Result := 'SERVERDATA_RESPONSE_VALUE'
  else if aType = SERVERDATA_EXECCOMMAND then
    Result := 'SERVERDATA_EXECCOMMAND'
  else if aType = SERVERDATA_AUTH_RESPONSE then
    Result := 'SERVERDATA_AUTH_RESPONSE'
  else if aType = SERVERDATA_AUTH then
    Result := 'SERVERDATA_AUTH';
end;

end.
