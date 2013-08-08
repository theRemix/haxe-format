package format.ett;

import haxe.io.*;

import format.csv.Reader in CSVReader;

import format.ett.Data;
import format.ett.Error;

import haxe.Unserializer;
import StringTools.trim;

class Reader {

	public var info:FileInfo;
	var csvReader:CSVReader;

	var context:Int;

	public function new( _input:Input ) {
		readFileInfo( _input );
	}

	public function readRecord():Dynamic {
		var data = csvReader.readRecord();
		if ( data.length != info.fields.length )
			throw GenericError( 'Expected #fields = ${info.fields.length} but was ${data.length}' );
		var r:Dynamic = cast {};
		for ( i in 0...info.fields.length ) {
			context = i;
			Reflect.setField( r, info.fields[i].name, parseData( data[i], info.fields[i].type ) );
		}
		return r;
	}

	function readFileInfo( input:Input ):Void {
		info = new FileInfo();

		var b:Null<Bytes> = null;

		b = readUntil( input, "NEWLINE-", BadStart );
		if ( b.length != 0 )
			throw BadStart;

		b = readUntil( input, "CODING-", NoCodingTag );
		if ( b.length == 0 )
			throw NoNewlineData;
		info.newline = b.toString();
		// trace( info );

		b = readUntil( input, info.newline, GenericError( "Missing newline sequence after CODING-<COD>" ) );
		if ( b.length == 0 )
			throw NoCodingData;
		switch ( b.toString() ) {
		case "ISO": info.encoding = ISO;
		case "UTF-8": info.encoding = UTF8;
		case all: throw BadCoding( all );
		}
		// trace( info );

		b = readUntil( input, "SEPARATOR-", NoSeparatorTag );
		if ( b.length != 0 )
			throw GenericError ( "Extra bytes between CODING-<COD><NEWLINE> and SEPARATOR-" );
		b = readUntil( input, info.newline, GenericError( "Missing newline sequence after SEPARATOR-<SEP>" ) );
		if ( b.length == 0 )
			throw NoSeparatorData;
		info.separator = b.toString();
		// trace( info );

		b = readUntil( input, "ESCAPE-", NoEscapeTag );
		if ( b.length != 0 )
			throw GenericError ( "Extra bytes between SEPARATOR-<SEP><NEWLINE> and ESCAPE-" );
		b = readUntil( input, info.newline, GenericError( "Missing newline sequence after ESCAPE-<SEP>" ) );
		if ( b.length == 0 )
			throw NoEscapeData;
		info.escape = b.toString();
		// trace( info );

		b = readUntil( input, "CLASS-", NoClassTag );
		if ( b.length != 0 )
			throw GenericError ( "Extra bytes between ESCAPE-<QTE><NEWLINE> and CLASS-" );
		b = readUntil( input, info.newline, GenericError( "Missing newline sequence after CLASS-<NAME>" ) );
		info.className = b.toString();
		// trace( info );

		var utf8 = switch ( info.encoding ) {
		case UTF8: true;
		case all: false;
		};
		csvReader = new CSVReader( input, info.newline, info.separator, info.escape, utf8 );

		var types = csvReader.readRecord().map( trim );
		var columns = csvReader.readRecord().map( trim );

		if ( types.length != columns.length )
			throw GenericError( "Number of types different from number of columns" );

		for ( i in 0...types.length ) {
			if ( columns[i].length == 0 )
				throw EmptyColumnName( i+1 );
			if ( types[i].length == 0 )
				throw EmptyColumnType( i+1 );
			var type = validateType( parseType( types[i] ) );
			info.fields.push( new Field( columns[i], type ) );
			// trace( info );
		}
	}

	function readUntil( input:Input, k:String, exception:ETTReaderError ):Bytes {
		var kb = Bytes.ofString( k );
		var buf = new BytesBuffer();
		var i:Int;
		var b:Int;
		while ( true ) {
			i = 0;
			while ( i < kb.length ) {
				try {
					b = input.readByte();
				}
				catch ( e:Eof ) {
					throw exception;
				}
				buf.addByte( b );
				if ( b != kb.get( i ) )
					break;
				i++;
			}
			if ( i == kb.length ) {
				var bufLen = buf.length;
				return buf.getBytes().sub( 0, bufLen - kb.length );
			}
		}
		return null;
	}

	/* 
	 * Recursively parses a type definition.
	 * Returns TUnknown( typeDef ) if the type is unknown.
	 */
	function parseType( typeDef:String ):Type {
		var nullable = ~/^Null<(.+)>$/;
		if ( nullable.match( typeDef ) ) {
			return TNull( parseType( nullable.matched( 1 ) ) );
		}

		var trimmable = ~/^Trim<(.+)>$/;
		if ( trimmable.match( typeDef ) ) {
			return TTrim( parseType( trimmable.matched( 1 ) ) );
		}

		return switch ( typeDef ) {
		case "Bool": TBool;
		case "Int": TInt;
		case "Float": TFloat;
		case "String": TString;
		case "Date": TDate;
		case "Timestamp": TTimestamp;
		case "HaxeSerial": THaxeSerial;
		case all: TUnknown( all );
		};
	}
	
	/* 
	 * Recursively validades a type.
	 */
	function validateType( t:Type ):Type {
		return switch ( t ) {
		case TNull( TNull( _ ) ): throw NullOfNull( t );
		case TNull( it ): TNull( validateType( it ) );
		case TTrim( TString ): t;
		case TTrim( TNull( _ ) ): throw TrimOfNull( t );
		case TTrim( _ ): throw InvalidTrim( t );
		case TUnknown( ts ): throw UnknownType( ts );
		case all: t;
		};
	}

	/* 
	 * Parses a field string value [s] using type [t].
	 */
	inline function parseData( s:String, t:Type ):Dynamic
		return _parseData( s, t, false );
	function _parseData( s:String, t:Type, nullable:Bool ):Dynamic {
		return switch ( t ) {
		case TNull( t ):

			_parseData( s, t, true );

		case TBool:

			switch ( trim( s ) ) {
			case "true":
				true;
			case "false":
				false;
			case "":
				if ( nullable ) null else throw NotNullable( info.fields[context] );
			case _:
				throw InvalidBoolean( s, info.fields[context] );
			};

		case TInt:

			s = trim( s );
			if ( s.length != 0 )
				encaps( Std.parseInt, s );
			else if ( nullable )
				null;
			else
				throw NotNullable( info.fields[context] );

		case TFloat:

			s = trim( s );
			if ( s.length != 0 )
				encaps( Std.parseFloat, s );
			else if ( nullable )
				null;
			else
				throw NotNullable( info.fields[context] );

		case TTrim( TString ):

			s = trim( s );
			_parseData( trim( s ), TString, nullable );

		case TString:

			if ( s.length != 0 )
				s;
			else if ( nullable )
				null;
			else
				throw NotNullable( info.fields[context] );

		case TDate:

			s = trim( s );
			if ( s.length != 0 )
				encaps( Date.fromString, s );
			else if ( nullable )
				null;
			else
				throw NotNullable( info.fields[context] );

		case TTimestamp:

			var tstamp:Null<Float> = _parseData( s, TFloat, nullable );
			if ( tstamp != null )
				encaps( Date.fromTime, tstamp );
			else
				null;

		case THaxeSerial:

			s = trim( s );
			if ( s.length != 0 )
				encaps( Unserializer.run, s );
			else if ( nullable )
				null;
			else
				throw NotNullable( info.fields[context] );

		case all:

			throw CannotParse( info.fields[context] );

		};
	}

	@:generic
	inline function encaps<T>( f:T->Dynamic, s:T ):Dynamic {
		try {
			return f( s );
		}
		catch ( e:Dynamic ) {
			throw GenericTypingError( e, info.fields[context] );
		}
	}

}