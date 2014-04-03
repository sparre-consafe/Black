with
  Ada.Strings.Fixed;
with
  URL_Utilities;
with
  Black.Text_IO;

package body Black.Request is

   function Compose (Method   : in HTTP.Methods;
                     Host     : in String;
                     Resource : in String) return Instance is
      use Ada.Strings.Unbounded;
   begin
      return (Blank             => False,
              Method            => Method,
              Host              => To_Unbounded_String (Host),
              Resource          => To_Unbounded_String (Resource),
              Parameters        => <>,
              Websocket         => False,
              Has_Websocket_Key => False,
              Websocket_Key     => <>);
   end Compose;

   function Has_Parameter (Request : in Instance;
                           Key     : in String) return Boolean is
      use Ada.Strings.Unbounded;
      use Black.Parameter.Vectors;
   begin
      for Index in Request.Parameters.First_Index ..
                   Request.Parameters.Last_Index loop
         if To_String (Request.Parameters.Element (Index).Key) = Key then
            return True;
         end if;
      end loop;

      return False;
   end Has_Parameter;

   function Host (Request : in Instance) return String is
      use Ada.Strings.Unbounded;
   begin
      if Request.Blank then
         raise Constraint_Error with "Request is blank.";
      elsif Request.Host = Null_Unbounded_String then
         raise Protocol_Error with "No host name was provided.";
      else
         return To_String (Request.Host);
      end if;
   end Host;

   function Method (Request : in Instance) return HTTP.Methods is
   begin
      if Request.Blank then
         raise Constraint_Error with "Request is blank.";
      else
         return Request.Method;
      end if;
   end Method;

   function Parameter (Request : in Instance;
                       Key     : in String;
                       Default : in String) return String is
      use Black.Parameter;
   begin
      return Request.Parameter (Key => Key);
   exception
      when No_Such_Parameter_Key | No_Such_Parameter_Value =>
         return Default;
   end Parameter;

   function Parameter (Request : in Instance;
                       Key     : in String) return String is
      use Black.Parameter;
      use Black.Parameter.Vectors;
   begin
      if not Request.Has_Parameter (Key => Key) then
         raise No_Such_Parameter_Key;
      end if;

      for Index in Request.Parameters.First_Index ..
                   Request.Parameters.Last_Index loop
         declare
            P : Black.Parameter.Instance renames
                  Request.Parameters.Element (Index);
         begin
            if Ada.Strings.Unbounded.To_String (P.Key) = Key then
               return Ada.Strings.Unbounded.To_String (P.Value);
            end if;
         end;
      end loop;

      raise No_Such_Parameter_Value;
   end Parameter;

   function Parameters (Request : in Instance)
                       return Black.Parameter.Vectors.Vector is
   begin
      if Request.Blank then
         raise Constraint_Error with "Request is blank.";
      else
         return Request.Parameters;
      end if;
   end Parameters;

   procedure Parse (Request : in out Instance;
                    Line    : in     Black.Parsing.Header_Line) is
      use type HTTP.Header_Key;
   begin
      if Line.Key = "Host" then
         Request.Host := Line.Value;
      elsif Line.Key = "Upgrade" and Line.Value = "websocket" then
         Request.Websocket := True;
      elsif Line.Key = "Sec-Websocket-Key" then
         Request.Websocket_Key := Line.Value;
         Request.Has_Websocket_Key := True;
      end if;
   end Parse;

   function Parse_HTTP
     (Stream : not null access Ada.Streams.Root_Stream_Type'Class)
     return Instance is
      use Ada.Strings.Unbounded;
      Header : Black.Parsing.Header;
      Line   : Black.Parsing.Header_Line;
   begin
      return R : Instance do
         R.Parse_Method_And_Resource (Text_IO.Get_Line (Stream));

         Header := Black.Parsing.Get (Stream);
         while not Black.Parsing.End_Of_Header (Header) loop
            Black.Parsing.Read (Stream => Stream,
                                From   => Header,
                                Item   => Line);
            R.Parse (Line);
         end loop;
      end return;
   end Parse_HTTP;

   procedure Parse_Method_And_Resource
     (Request : in out Instance;
      Line    : in     Ada.Strings.Unbounded.Unbounded_String) is

      function Parse_Parameters (Raw : in String)
                                return Black.Parameter.Vectors.Vector;

      function Parse_Parameters (Raw : in String)
                                return Black.Parameter.Vectors.Vector is
         use Ada.Strings.Fixed;
         From : Positive := Raw'First;
         Next : Positive;
      begin
         return Result : Black.Parameter.Vectors.Vector do
            loop
               exit when From > Raw'Last;

               Next := Index (Raw (From .. Raw'Last) & "&", "&");

               declare
                  use Ada.Strings.Unbounded;
                  Current : constant String := Raw (From .. Next - 1);
                  Equals  : constant Natural := Index (Current, "=");
               begin
                  if Equals in Current'Range then
                     Result.Append
                       ((Key        => To_Unbounded_String
                                         (URL_Utilities.Decode
                                           (Current
                                              (Current'First .. Equals - 1))),
                         With_Value => True,
                         Value      => To_Unbounded_String
                                         (URL_Utilities.Decode
                                           (Current
                                              (Equals + 1 .. Current'Last)))));
                  else
                     Result.Append ((Key        => To_Unbounded_String
                                                     (URL_Utilities.Decode
                                                        (Current)),
                                     With_Value => False));
                  end if;
               end;

               From := Next + 1;
            end loop;
         end return;
      end Parse_Parameters;

      use Ada.Strings.Unbounded;
      First_Space  : constant Natural := Index (Line, " ");
      Second_Space : constant Natural := Index (Line, " ", First_Space + 1);
   begin
      if Second_Space = 0 then
         raise Protocol_Error;
      else
         Parse_Method :
         declare
            Method : constant String := (Slice (Line, 1, First_Space - 1));
         begin
            Request.Method := HTTP.Methods'Value (Method);
         exception
            when Constraint_Error =>
               raise Protocol_Error
                 with """" & Method & """ is not a recognised HTTP method.";
         end Parse_Method;

         Parse_Resource_And_Parameters :
         begin
            if Second_Space - First_Space > 1 then
               declare
                  Parameter_Marker : constant Natural :=
                    Index (Line, "?", First_Space + 1);
               begin
                  if Parameter_Marker in 1 .. Second_Space - 1 then
                     Request.Resource :=
                       To_Unbounded_String
                         (URL_Utilities.Decode
                            (Slice (Source => Line,
                                    Low    => First_Space + 1,
                                    High   => Parameter_Marker - 1)));
                     Request.Parameters :=
                       Parse_Parameters (Slice (Source => Line,
                                                Low    => Parameter_Marker + 1,
                                                High   => Second_Space - 1));
                  else
                     Request.Resource :=
                       To_Unbounded_String
                         (URL_Utilities.Decode
                            (Slice (Source => Line,
                                    Low    => First_Space + 1,
                                    High   => Second_Space - 1)));
                  end if;
               end;
            else
               raise Protocol_Error
                 with "Empty resource identifier.";
            end if;
         end Parse_Resource_And_Parameters;

         Parse_Protocol_Version :
         begin
            if Slice (Line, Second_Space + 1, Length (Line)) /= "HTTP/1.1" then
               raise Protocol_Error
                 with "HTTP 1.1 is the only supported protocol version.";
            end if;
         end Parse_Protocol_Version;

         Request.Blank := False;
      end if;
   end Parse_Method_And_Resource;

   function Resource (Request : in Instance) return String is
   begin
      if Request.Blank then
         raise Constraint_Error with "Request is blank.";
      else
         return Ada.Strings.Unbounded.To_String (Request.Resource);
      end if;
   end Resource;

   function Want_Websocket (Request : in Instance) return Boolean is
   begin
      if Request.Blank then
         raise Constraint_Error with "Request is blank.";
      else
         return Request.Websocket;
      end if;
   end Want_Websocket;

   function Websocket_Key  (Request : in Instance) return String is
   begin
      if Request.Blank then
         raise Constraint_Error with "Request is blank.";
      elsif not Request.Websocket then
         raise Constraint_Error with "Not a websocket request.";
      elsif Request.Has_Websocket_Key then
         return Ada.Strings.Unbounded.To_String (Request.Websocket_Key);
      else
         raise Protocol_Error with "Request has no websocket key.";
      end if;
   end Websocket_Key;
end Black.Request;
