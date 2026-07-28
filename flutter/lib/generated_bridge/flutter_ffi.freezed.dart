// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'flutter_ffi.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EventToUI {

 Object get field0;



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventToUI&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));

@override
String toString() {
  return 'EventToUI(field0: $field0)';
}


}

/// @nodoc
class $EventToUICopyWith<$Res>  {
$EventToUICopyWith(EventToUI _, $Res Function(EventToUI) __);
}


/// Adds pattern-matching-related methods to [EventToUI].
extension EventToUIPatterns on EventToUI {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( EventToUI_Event value)?  event,TResult Function( EventToUI_Rgba value)?  rgba,TResult Function( EventToUI_Texture value)?  texture,required TResult orElse(),}){
final _that = this;
switch (_that) {
case EventToUI_Event() when event != null:
return event(_that);case EventToUI_Rgba() when rgba != null:
return rgba(_that);case EventToUI_Texture() when texture != null:
return texture(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( EventToUI_Event value)  event,required TResult Function( EventToUI_Rgba value)  rgba,required TResult Function( EventToUI_Texture value)  texture,}){
final _that = this;
switch (_that) {
case EventToUI_Event():
return event(_that);case EventToUI_Rgba():
return rgba(_that);case EventToUI_Texture():
return texture(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( EventToUI_Event value)?  event,TResult? Function( EventToUI_Rgba value)?  rgba,TResult? Function( EventToUI_Texture value)?  texture,}){
final _that = this;
switch (_that) {
case EventToUI_Event() when event != null:
return event(_that);case EventToUI_Rgba() when rgba != null:
return rgba(_that);case EventToUI_Texture() when texture != null:
return texture(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  event,TResult Function( int field0)?  rgba,TResult Function( int field0,  bool field1)?  texture,required TResult orElse(),}) {final _that = this;
switch (_that) {
case EventToUI_Event() when event != null:
return event(_that.field0);case EventToUI_Rgba() when rgba != null:
return rgba(_that.field0);case EventToUI_Texture() when texture != null:
return texture(_that.field0,_that.field1);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  event,required TResult Function( int field0)  rgba,required TResult Function( int field0,  bool field1)  texture,}) {final _that = this;
switch (_that) {
case EventToUI_Event():
return event(_that.field0);case EventToUI_Rgba():
return rgba(_that.field0);case EventToUI_Texture():
return texture(_that.field0,_that.field1);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  event,TResult? Function( int field0)?  rgba,TResult? Function( int field0,  bool field1)?  texture,}) {final _that = this;
switch (_that) {
case EventToUI_Event() when event != null:
return event(_that.field0);case EventToUI_Rgba() when rgba != null:
return rgba(_that.field0);case EventToUI_Texture() when texture != null:
return texture(_that.field0,_that.field1);case _:
  return null;

}
}

}

/// @nodoc


class EventToUI_Event extends EventToUI {
  const EventToUI_Event(this.field0): super._();


@override final  String field0;

/// Create a copy of EventToUI
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventToUI_EventCopyWith<EventToUI_Event> get copyWith => _$EventToUI_EventCopyWithImpl<EventToUI_Event>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventToUI_Event&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventToUI.event(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventToUI_EventCopyWith<$Res> implements $EventToUICopyWith<$Res> {
  factory $EventToUI_EventCopyWith(EventToUI_Event value, $Res Function(EventToUI_Event) _then) = _$EventToUI_EventCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EventToUI_EventCopyWithImpl<$Res>
    implements $EventToUI_EventCopyWith<$Res> {
  _$EventToUI_EventCopyWithImpl(this._self, this._then);

  final EventToUI_Event _self;
  final $Res Function(EventToUI_Event) _then;

/// Create a copy of EventToUI
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventToUI_Event(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EventToUI_Rgba extends EventToUI {
  const EventToUI_Rgba(this.field0): super._();


@override final  int field0;

/// Create a copy of EventToUI
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventToUI_RgbaCopyWith<EventToUI_Rgba> get copyWith => _$EventToUI_RgbaCopyWithImpl<EventToUI_Rgba>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventToUI_Rgba&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EventToUI.rgba(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EventToUI_RgbaCopyWith<$Res> implements $EventToUICopyWith<$Res> {
  factory $EventToUI_RgbaCopyWith(EventToUI_Rgba value, $Res Function(EventToUI_Rgba) _then) = _$EventToUI_RgbaCopyWithImpl;
@useResult
$Res call({
 int field0
});




}
/// @nodoc
class _$EventToUI_RgbaCopyWithImpl<$Res>
    implements $EventToUI_RgbaCopyWith<$Res> {
  _$EventToUI_RgbaCopyWithImpl(this._self, this._then);

  final EventToUI_Rgba _self;
  final $Res Function(EventToUI_Rgba) _then;

/// Create a copy of EventToUI
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EventToUI_Rgba(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class EventToUI_Texture extends EventToUI {
  const EventToUI_Texture(this.field0, this.field1): super._();


@override final  int field0;
 final  bool field1;

/// Create a copy of EventToUI
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EventToUI_TextureCopyWith<EventToUI_Texture> get copyWith => _$EventToUI_TextureCopyWithImpl<EventToUI_Texture>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EventToUI_Texture&&(identical(other.field0, field0) || other.field0 == field0)&&(identical(other.field1, field1) || other.field1 == field1));
}


@override
int get hashCode => Object.hash(runtimeType,field0,field1);

@override
String toString() {
  return 'EventToUI.texture(field0: $field0, field1: $field1)';
}


}

/// @nodoc
abstract mixin class $EventToUI_TextureCopyWith<$Res> implements $EventToUICopyWith<$Res> {
  factory $EventToUI_TextureCopyWith(EventToUI_Texture value, $Res Function(EventToUI_Texture) _then) = _$EventToUI_TextureCopyWithImpl;
@useResult
$Res call({
 int field0, bool field1
});




}
/// @nodoc
class _$EventToUI_TextureCopyWithImpl<$Res>
    implements $EventToUI_TextureCopyWith<$Res> {
  _$EventToUI_TextureCopyWithImpl(this._self, this._then);

  final EventToUI_Texture _self;
  final $Res Function(EventToUI_Texture) _then;

/// Create a copy of EventToUI
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,Object? field1 = null,}) {
  return _then(EventToUI_Texture(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as int,null == field1 ? _self.field1 : field1 // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
