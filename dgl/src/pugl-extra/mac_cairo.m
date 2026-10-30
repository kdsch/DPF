// Copyright 2019-2022 David Robillard <d@drobilla.net>
// SPDX-License-Identifier: ISC

// This replaces pugl-upstream/src/mac_cairo.m, which draws through a Quartz
// surface on the view's CGContext. Quartz can't draw text in a FreeType font, and
// Cairo can't fall back to its image backend there because a view's context is
// not a bitmap context. With that surface, r4's panel painted its background and
// nothing after it. Here Cairo draws into an image surface, and each expose
// copies the surface to the view.

#include "../pugl-upstream/src/internal.h"
#include "../pugl-upstream/src/mac.h"
#include "../pugl-upstream/src/stub.h"

#include <pugl/cairo.h>

#include <cairo.h>

#import <Cocoa/Cocoa.h>

#include <assert.h>

@interface PuglCairoView : NSView
@end

@implementation PuglCairoView {
@public
  PuglView*        puglview;
  cairo_surface_t* surface;
  cairo_t*         cr;
}

-(BOOL)acceptsFirstMouse:(NSEvent*)event
{
  return YES;
}

- (id)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];

  return self;
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize
{
  PuglWrapperView* wrapper = (PuglWrapperView*)[self superview];

  [super resizeWithOldSuperviewSize:oldSize];
  [wrapper setReshaped];
}

- (void)drawRect:(NSRect)rect
{
  PuglWrapperView* wrapper = (PuglWrapperView*)[self superview];
  [wrapper dispatchExpose:rect];
}

@end

static PuglStatus
puglMacCairoCreate(PuglView* view)
{
  PuglInternals* impl     = view->impl;
  PuglCairoView* drawView = [PuglCairoView alloc];

  drawView->puglview = view;
  [drawView initWithFrame:[impl->wrapperView bounds]];

  // A host may resize even a view that isn't resizable, as Reaper does to an LV2
  // UI. The draw view must match, because pugl computes a damaged rectangle's
  // place in it from the configured height.
  [drawView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

  // A child view is configured only when something resizes it, and a host may
  // never do that. The first expose must configure it, or it draws at no size.
  [impl->wrapperView setReshaped];

  impl->drawView = drawView;
  return PUGL_SUCCESS;
}

static void
puglMacCairoDestroy(PuglView* view)
{
  PuglCairoView* const drawView = (PuglCairoView*)view->impl->drawView;

  [drawView removeFromSuperview];
  [drawView release];

  view->impl->drawView = nil;
}

static PuglStatus
puglMacCairoEnter(PuglView* view, const PuglExposeEvent* expose)
{
  PuglCairoView* const drawView = (PuglCairoView*)view->impl->drawView;
  if (!expose) {
    return PUGL_SUCCESS;
  }

  assert(!drawView->surface);
  assert(!drawView->cr);

  drawView->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                 (int)view->lastConfigure.width,
                                                 (int)view->lastConfigure.height);

  drawView->cr = cairo_create(drawView->surface);

  return PUGL_SUCCESS;
}

// A view's context may draw the image after the expose ends, so the image holds
// the surface until the context lets go of it.
static void
puglMacCairoReleaseSurface(void* info, const void* data, size_t size)
{
  (void)data;
  (void)size;

  cairo_surface_destroy((cairo_surface_t*)info);
}

static PuglStatus
puglMacCairoLeave(PuglView* view, const PuglExposeEvent* expose)
{
  PuglCairoView* const drawView = (PuglCairoView*)view->impl->drawView;
  if (!expose) {
    return PUGL_SUCCESS;
  }

  assert(drawView->surface);
  assert(drawView->cr);

  cairo_surface_t* const surface = drawView->surface;

  cairo_destroy(drawView->cr);
  cairo_surface_flush(surface);
  drawView->cr      = NULL;
  drawView->surface = NULL;

  const size_t width  = (size_t)cairo_image_surface_get_width(surface);
  const size_t height = (size_t)cairo_image_surface_get_height(surface);
  const size_t stride = (size_t)cairo_image_surface_get_stride(surface);

  CGDataProviderRef provider =
    CGDataProviderCreateWithData(surface,
                                 cairo_image_surface_get_data(surface),
                                 stride * height,
                                 puglMacCairoReleaseSurface);

  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

  CGImageRef image =
    CGImageCreate(width,
                  height,
                  8,
                  32,
                  stride,
                  colorSpace,
                  kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst,
                  provider,
                  NULL,
                  false,
                  kCGRenderingIntentDefault);

  // The draw view isn't flipped, so the image's top meets the view's top.
  const double scale = 1.0 / [[NSScreen mainScreen] backingScaleFactor];
  const CGRect rect  = {
    {0.0, [drawView bounds].size.height - ((double)height * scale)},
    {(double)width * scale, (double)height * scale}};

  CGContextDrawImage(
    (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort],
    rect,
    image);

  CGImageRelease(image);
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(provider);

  return PUGL_SUCCESS;
}

static void*
puglMacCairoGetContext(PuglView* view)
{
  return ((PuglCairoView*)view->impl->drawView)->cr;
}

const PuglBackend*
puglCairoBackend(void)
{
  static const PuglBackend backend = {puglStubConfigure,
                                      puglMacCairoCreate,
                                      puglMacCairoDestroy,
                                      puglMacCairoEnter,
                                      puglMacCairoLeave,
                                      puglMacCairoGetContext};

  return &backend;
}
