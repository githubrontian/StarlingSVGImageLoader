/*
 Copyright (c) 2009 by contributors:

 * James Hight (http://labs.zavoo.com/)
 * Richard R. Masters
 * Google Inc. (Brad Neuberg -- http://codinginparadise.org)

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
*/

package org.svgweb.core
{
    import flash.display.CapsStyle;
    import flash.display.DisplayObject;
    import flash.display.JointStyle;
    import flash.display.LineScaleMode;
    import flash.display.Shape;
    import flash.events.Event;
    import flash.events.EventDispatcher;
    import flash.events.MouseEvent;
    import flash.geom.Matrix;
    import flash.geom.Rectangle;
    import flash.utils.getDefinitionByName;
    import flash.utils.getQualifiedClassName;
    
    import org.svgweb.nodes.*;
    import org.svgweb.utils.SVGCoordinate;
    import org.svgweb.utils.SVGUnits;

    /** Base node extended by all other SVG Nodes **/
    public class SVGNode extends EventDispatcher
    {
        public static const ATTRIBUTES_NOT_INHERITED:Array = ['id', 'x', 'y', 'width', 'height', 'rotate', 'transform', 
                                                'gradientTransform', 'opacity', 'mask', 'clip-path', 'href', 'target',
                                                'viewBox', 'preserveAspectRatio'];
        
        public static const INVALID_ATTR_NONE:uint        = 0;
        public static const INVALID_ATTR_OPACITY:uint     = 1;
        public static const INVALID_ATTR_TRANSFORM:uint   = 2;
        public static const INVALID_ATTR_VISIBILITY:uint  = 4;
        public static const INVALID_ATTR_DISPLAY:uint     = 8;

        public namespace xlink = 'http://www.w3.org/1999/xlink';
        public namespace svg = 'http://www.w3.org/2000/svg';
        public namespace aaa = 'http://www.w3.org/XML/1998/namespace';
       
        public var svgRoot:SVGSVGNode = null;
        public var svgParent:SVGNode = null;
        public var svgChildren:Array = new Array();
        public var svgClipPathMask:SVGNode = null;
        public var isMask:Boolean = false;

        //Used for gradients
        public var xMin:Number;
        public var xMax:Number;
        public var yMin:Number;
        public var yMax:Number;

        protected var _parsedChildren:Boolean = false;
        public var _initialRenderDone:Boolean = false;

        protected var _firstX:Boolean = true;
        protected var _firstY:Boolean = true;

        protected var _xml:XML;
        protected var _invalidDisplay:Boolean = false;
        protected var _invalidAttribute:uint = INVALID_ATTR_NONE;
        protected var _id:String = null;
        protected var _graphicsCommands:Array;
        protected var _styles:Object;

        protected var original:SVGNode;
        protected var _isClone:Boolean = false;
        protected var _clones:Array = new Array();
        
        protected var animations:Array = new Array();
        
        // cache the matrix to aid any zooming and panning operations
        // later
        protected var _lastVBMatrix:Matrix;
        
        /**
         *
         * To handle certain flash quirks, and to support certain SVG features,
         * the implementation of one SVG node is split into one to four
         * Sprites which perform the functions of transforming, clipping, and drawing.
         * Here are the specific functions performed by each sprite:
         *
         * topSprite:
         *      * top sprite, used display list handling (parent/child relationships)
         *      * handles the transform attribute
         *      * mouse, stage, frame events
         *      * handles visibility
         *      * is the parent of the clip-path mask
         *      * has mask set to 'default' mask (top level bounding box)
         *
         * clipSprite:
         *      * has mask set to 'clip-path' mask
         *
         * drawSprite:
         *      * handles all graphics access
         *      * handles x,y,rotate,opacity attributes
         *      * filters added here
         *
         * viewBoxSprite:
         *      * handles viewBox transform
         *      * parent of SVG children
         *
         */
        public var topSprite:SVGSprite;
        public var clipSprite:SVGSprite;
        public var drawSprite:SVGSprite;
        public var viewBoxSprite:SVGSprite;

        /**
         * Constructor
         *
         * @param xml XML object containing the SVG document. @default null
         *
         * @return void.
         */
        public function SVGNode(svgRoot:SVGSVGNode, xml:XML = null, original:SVGNode = null):void {
            this.svgRoot = svgRoot;

            this.xml = xml;
            if (original) {
                this.original = original;
                this._isClone = true;
            }

            if (topSprite) {
                topSprite.addEventListener(Event.ADDED, onAddedToStage);
                topSprite.addEventListener(Event.REMOVED, onRemovedFromStage);
            }
            //increment('SVGNode_Constructor', new Date().getTime() - t);
        }

        public function createSVGSprites():void {

            topSprite = new SVGSprite(this);

            // This handle strange gradient bugs with negative transforms
            // by separating the transform from the drawing object
            if ( getAttribute('transform') != null 
                  || getStyleOrAttr('clip-path') != null ) {
                clipSprite = new SVGSprite(this);
                topSprite.addChild(clipSprite);
            }
            else {
                clipSprite = topSprite;
            }

            // If the object has a gaussian filter, flash will blur the object mask,
            // even if the mask is not drawn with a blur. This is not correct rendering.
            // So, we use a stub parent object to hold the mask, in order to isolate the
            // mask from the filter. A child is created for drawing and the
            // filter is applied to the child.
            // FIXME: Currently x and y are on the drawSprite. Try to move
            // to transform sprite.
            if ( getStyleOrAttr('clip-path') != null
                       || getAttribute('x') != null
                       || getAttribute('y') != null ) {
                drawSprite = new SVGSprite(this);
                clipSprite.addChild(drawSprite);
            }
            else {
                drawSprite = clipSprite;
            }

            // If the object has a viewBox, the resulting transform should only apply to the
            // children of the object, so create a child sprite to hold the transform.
            // If the object is a text node, we put the TextField on the drawSprite instead of
            // the viewBoxSprite because it is simpler all children of viewBoxSprite are SVGSprites.
            if ( getAttribute('viewBox') != null
                    || (this is SVGSVGNode)  || (this is SVGTextNode) ) {
                viewBoxSprite = new SVGSprite(this);
                drawSprite.addChild(viewBoxSprite);
            }
            else {
                viewBoxSprite = drawSprite;
            }
        }


        /**
         * Parse the SVG XML.
         * This handles creation of child nodes.
         **/
        protected function parseChildren():void {
            var text:String = '';
            for each (var childXML:XML in this._xml.children()) {
                if (childXML.nodeKind() == 'element') {
                    // If we support text values then set them
                    if (this.hasText()) {
                        if (childXML.localName() == '__text'
                            && childXML.children().length() > 0) {
                            // for the SVGViewerWeb we use a nested
                            // SVGDOMTextNode to store the actual value; this
                            // class is necessary so that we can do text
                            // node detection in the browser and have a unique
                            // GUID per DOM text node
                            text += childXML.children().toString();
                        }
                    }

                    var newChildNode:SVGNode = this.parseNode(childXML);
                    if (!newChildNode) {
                        continue;
                    }
                    this.addSVGChild(newChildNode);
                } else if (childXML.nodeKind() == 'text'
                           && this.hasText()) {
                    text = this._xml.text().toString();
                }  
            }
            
            if (this.hasText()) {
                this.setText(text);
            }
        }

        public function parseNode(childXML:XML):SVGNode {
            var childNode:SVGNode = null;
            var nodeName:String = childXML.localName();                    
            nodeName = nodeName.toLowerCase();
            switch(nodeName) {
                case "a":
                    childNode = new SVGANode(this.svgRoot, childXML);
                    break;
                case "animate":
                    childNode = new SVGAnimateNode(this.svgRoot, childXML);
                    break;    
                case "animatemotion":
                    childNode = new SVGAnimateMotionNode(this.svgRoot, childXML);
                    break;    
                case "animatecolor":
                    childNode = new SVGAnimateColorNode(this.svgRoot, childXML);
                    break;    
                case "animatetransform":
                    childNode = new SVGAnimateTransformNode(this.svgRoot, childXML);
                    break;    
                case "audio":
                    childNode = new SVGAudioNode(this.svgRoot, childXML);
                    break;
                case "circle":
                    childNode = new SVGCircleNode(this.svgRoot, childXML);
                    break;        
                case "clippath":
                    childNode = new SVGClipPathNode(this.svgRoot, childXML);
                    break;
                case "desc":
                    childNode = new SVGDescNode(this.svgRoot, childXML);
                    break;
                case "defs":
                    childNode = new SVGDefsNode(this.svgRoot, childXML);
                    break;
                case "ellipse":
                    childNode = new SVGEllipseNode(this.svgRoot, childXML);
                    break;
                case "filter":
                    childNode = new SVGFilterNode(this.svgRoot, childXML);
                    break;
                case "font":
                    childNode = new SVGFontNode(this.svgRoot, childXML);
                    break;
                case "font-face":
                    childNode = new SVGFontFaceNode(this.svgRoot, childXML);
                    break;
                case "g":                        
                    childNode = new SVGGroupNode(this.svgRoot, childXML);
                    break;
                case "glyph":                        
                    childNode = new SVGGlyphNode(this.svgRoot, childXML);
                    break;
                case "image":                        
                    childNode = new SVGImageNode(this.svgRoot, childXML);
                    break;
                case "line": 
                    childNode = new SVGLineNode(this.svgRoot, childXML);
                    break;    
                case "lineargradient": 
                    childNode = new SVGLinearGradient(this.svgRoot, childXML);
                    break;    
                case "mask":
                    childNode = new SVGMaskNode(this.svgRoot, childXML);
                    break;                        
                case "metadata":
                    childNode = new SVGMetadataNode(this.svgRoot, childXML);
                    break;
                case "missing-glyph":                        
                    childNode = new SVGMissingGlyphNode(this.svgRoot, childXML);
                    break;
                case "mpath":
                    childNode = new SVGMPathNode(this.svgRoot, childXML);
                    break;
                case "pattern":
                    childNode = new SVGPatternNode(this.svgRoot, childXML);
                    break;
                case "polygon":
                    childNode = new SVGPolygonNode(this.svgRoot, childXML);
                    break;
                case "polyline":
                    childNode = new SVGPolylineNode(this.svgRoot, childXML);
                    break;
                case "path":                        
                    childNode = new SVGPathNode(this.svgRoot, childXML);
                    break;
                case "radialgradient": 
                    childNode = new SVGRadialGradient(this.svgRoot, childXML);
                    break;    
                case "rect":
                    childNode = new SVGRectNode(this.svgRoot, childXML);
                    break;
                case "script":
                    childNode = new SVGScriptNode(this.svgRoot, childXML);
                    break;
                case "set":
                    childNode = new SVGSetNode(this.svgRoot, childXML);
                    break;
                case "stop":
                    childNode = new SVGStopNode(this.svgRoot, childXML);            
                    break;
                case "svg":
                    childNode = new SVGSVGNode(this.svgRoot, childXML, null, this.svgRoot.viewer);
                    break;                        
                case "symbol":
                    childNode = new SVGSymbolNode(this.svgRoot, childXML);
                    break;                        
                case "text":    
                    childNode = new SVGTextNode(this.svgRoot, childXML);
                    break; 
                case "title":    
                    childNode = new SVGTitleNode(this.svgRoot, childXML);
                    break; 
                case "tspan":                        
                    childNode = new SVGTspanNode(this.svgRoot, childXML);
                    break; 
                case "use":
                    childNode = new SVGUseNode(this.svgRoot, childXML);
                    break;
                case "video":
                    childNode = new SVGVideoNode(this.svgRoot, childXML);
                    break;
                case "__text":
                    /** These are fake text nodes necessary for integration
                        with the browser through JavaScript. */
                    childNode = new SVGDOMTextNode(this.svgRoot, childXML);
                    break;
                case "null":
                    break;
                    
                default:
                    trace("Unknown Element: " + nodeName);
                    childNode = new SVGUnknownNode(this.svgRoot, childXML);
                    break;    
            }

            return childNode;
        }
        
        /**
         * Called when a node is created after page load with XML content
         * added as a child. Forces a parse.
         */
        public function forceParse():void {
            if (this._xml != null && !this._parsedChildren) {
                this.parseChildren();
                for (var i:uint = 0; i < this.svgChildren.length; i++) {
                    var child:SVGNode = this.svgChildren[i];
                    child.forceParse();
                }
                
                this._parsedChildren = true;
            } 
        }

        /**
         * Triggers on ENTER_FRAME event
         * Redraws node graphics if _invalidDisplay == true
         **/
        protected function drawNode(event:Event = null):void {
            if ( this.topSprite.parent != null && this._invalidDisplay) {
                     
                // are we in the middle of a suspendRedraw operation?
                if (this.svgRoot.viewer && this.svgRoot.viewer.isSuspended) {
                    return;
                }
                //var t:int;
                //var pieceTime:int;
                this._invalidDisplay = false;
                if (this._xml != null) {
                    //t = new Date().getTime();
                    //pieceTime = new Date().getTime();
                    drawSprite.graphics.clear();
                    //increment('drawNode_graphics.clear', new Date().getTime() - pieceTime);

                    //pieceTime = new Date().getTime();
                    if (!this._parsedChildren) {
                        this.parseChildren();
                        this._parsedChildren = true;
                    }
                    //increment('drawNode_parseChildren', new Date().getTime() - pieceTime);

                    // sets x, y, rotate, and opacity
                    //pieceTime = new Date().getTime();
                    this.setAttributes();
                    //increment('drawNode_setAttributes', new Date().getTime() - pieceTime);

                    //pieceTime = new Date().getTime();
                    if (this.getStyleOrAttr('visibility') == 'hidden') {
                        // SVG spec says visibility='hidden' should fully draw
                        // the shape with full stroke widths, etc., 
                        // just make it invisible. It also states that
                        // all children should be invisible _unless_ they
                        // explicitly have a visibility set to 'visible'.
                        this.setVisibility('hidden');
                    } else {
                        //increment('drawNode_getStyleOrAttr(visibility)', new Date().getTime() - pieceTime);
                        //pieceTime = new Date().getTime();
                        this.setVisibility('visible');
                        //increment('drawNode_setVisibility', new Date().getTime() - pieceTime);
                    }
                    
                    //pieceTime = new Date().getTime();
                    if (this.getStyleOrAttr('display', null, false) == 'none') {
                        this.topSprite.visible = false;
                    }
                    else {
                        //increment('drawNode_getStyleOrAttr(display)', new Date().getTime() - pieceTime);
                        this.topSprite.visible = true;
                    }
                    // Continue to draw even if display="none".  Animation of
                    // display attribute independent of drawNode() relies on the
                    // correct drawing state

                    //pieceTime = new Date().getTime();
                    // <svg> nodes get an implicit mask of their height and width
                    if (this is SVGSVGNode) {
                        this.applyDefaultMask();
                    }
                    //increment('drawNode_applyDefaultMask', new Date().getTime() - pieceTime);

                    //pieceTime = new Date().getTime();
                    this.generateGraphicsCommands();
                    //increment('drawNode_generateGraphicsCommands', new Date().getTime() - pieceTime);
                    //pieceTime = new Date().getTime();
                    this.transformNode();
                    //increment('drawNode_transformNode', new Date().getTime() - pieceTime);
                    //pieceTime = new Date().getTime();
                    this.draw();
                    //increment('drawNode_draw', new Date().getTime() - pieceTime);

                    //pieceTime = new Date().getTime();
                    this.applyClipPathMask();
                    //increment('drawNode_applyClipPathMask', new Date().getTime() - pieceTime);
                    //pieceTime = new Date().getTime();
                    this.applyViewBox();
                    //increment('drawNode_applyViewBox', new Date().getTime() - pieceTime);
                    //pieceTime = new Date().getTime();
                    this.setupFilters();
                    //increment('drawNode_setupFilters', new Date().getTime() - pieceTime);
                }
                
                //pieceTime = new Date().getTime();
                topSprite.removeEventListener(Event.ENTER_FRAME, drawNode);
                //increment('drawNode_removeEventListener', new Date().getTime() - pieceTime);

                //pieceTime = new Date().getTime();
                if (this.xml.@id)  {
                    //increment('drawNode_xml.@id', new Date().getTime() - pieceTime);
                    //pieceTime = new Date().getTime();
                    this.svgRoot.invalidateReferers(this.xml.@id);
                    //increment('drawNode_invalidateReferers', new Date().getTime() - pieceTime);
                }

                //pieceTime = new Date().getTime();
                if (getPatternAncestor() != null) {
                    //increment('drawNode_getPatternAncestor', new Date().getTime() - pieceTime);
                    //pieceTime = new Date().getTime();
                    this.svgRoot.invalidateReferers(getPatternAncestor().id);
                    //increment('drawNode_invalidateReferers', new Date().getTime() - pieceTime);
                }

                //increment('drawNodeTOTAL', new Date().getTime() - t);
            }
            
            if (!this._initialRenderDone && this.topSprite.parent) {
                this.attachEventListeners();
                this._initialRenderDone = true;
                this.svgRoot.renderFinished();
            }
        }

        protected function setAttributes():void {
            this.loadAttribute('x');
            this.loadAttribute('y');
            this.loadAttribute('rotate','rotation');
            this.loadAttribute('opacity', 'alpha', true);
            if (this.getStyleOrAttr('pointer-events') == 'none') {
                topSprite.mouseEnabled = false;
                topSprite.mouseChildren = false;
            }
            else {
                topSprite.mouseEnabled = true;
                topSprite.mouseChildren = true;
            }
        }

        /**
         * Load an XML attribute into the current node
         * 
         * @param name Name of the XML attribute to load
         * @param field Name of the node field to set. If null, the name attribute will be used as the field attribute.
         * @param applyStyle Boolean Optional parameter that controls whether we
         * will look in this node's style value if the given name is not in
         * the node's attribute list. Defaults to false.
         **/
        protected function loadAttribute(name:String, field:String = null,
                                         applyStyle:Boolean = false):void {
            if (field == null) {
                field = name;
            }
            var tmp:String = this.getStyleOrAttr(name);
            if (tmp != null) {
                switch (name) {
                    case 'x':
                        drawSprite[field] = SVGUnits.parseNumPct(tmp, this.getWidth());
                        break;
                    case 'y':
                        drawSprite[field] = SVGUnits.parseNumPct(tmp, this.getHeight());
                        break;
                    case 'rotate':
                        drawSprite[field] = SVGUnits.parseNum(tmp);
                        break;
                    case 'opacity':
                        drawSprite[field] = SVGUnits.parseNum(tmp);
                        break;
                }
            }
        } 

        /** Sets this node and all its children to the given visibility value.
            If a child has an explicit visibility setting then that is retained
            independent of what we set here.
            
            @param visible - If 'visible', sets this node to be visible. 
            The value 'hidden' will hide it.
            @param recursive - Internal variable. Should not set. */
        protected function setVisibility(visible:String, 
                                         recursive:Boolean = false):void {
            // FIXME: Turn this into an iterative rather than a recursive
            // method
            //this.dbg('setVisibility, this='+this.xml.localName()+', visible='+visible+', recursive='+recursive);
            // ignore if we have our own visibility value and we are a recursive
            // call
            if (recursive && (this.getStyleOrAttr('visibility', null, false) != null)) {
                return;
            }
            if (drawSprite) {
                if (visible == 'visible') {
                    drawSprite.alpha = SVGUnits.parseNum(this.getStyleOrAttr('opacity'));
                } else {
                    drawSprite.alpha = 0;
                }
            }
            
            // set on all our children
            // ??? setting alpha on the node affects all the children
            // setting alpha = 0 means all children are hidden, regardless
            // of their own alpha values
            var child:SVGNode;
            for (var i:uint = 0; i < this.svgChildren.length; i++) {
                child = this.svgChildren[i];
                child.setVisibility(visible, true);
            }
        }

        // <svg> and <image> nodes get an implicit mask of their height and width
        public function applyDefaultMask():void {
            if ( (this is SVGImageNode &&
                   this.getAttribute('width') != null &&
                   this.getAttribute('height') != null )
               || this is SVGSVGNode ) {
                if (topSprite.mask == null) {
                    var myMask:Shape = new Shape();
                    topSprite.parent.addChild(myMask);
                    topSprite.mask = myMask;
                }
                if (topSprite.mask is Shape) {
                    Shape(topSprite.mask).graphics.clear();
                    Shape(topSprite.mask).graphics.beginFill(0x000000);
                    Shape(topSprite.mask).transform.matrix=topSprite.transform.matrix.clone();
                    drawSprite.graphics.clear();
                    drawSprite.graphics.beginFill(0x000000, 0);
                    var canvasWidth:Number;
                    var canvasHeight:Number;
                   /* if (this.topSprite.parent is SVGViewerWeb) {
                        var clipMode:String= SVGViewerWeb(this.topSprite.parent).getClipMode();
                        //this.dbg("<svg> clip mode: "+ clipMode);
                        switch (clipMode) {
                           case 'height':
                             canvasWidth = SVGViewer(this.topSprite.parent).getWidth();
                             canvasHeight = this.getHeight();
                             break;
                           case 'neither':
                             canvasWidth = SVGViewer(this.topSprite.parent).getWidth();
                             canvasHeight = SVGViewer(this.topSprite.parent).getHeight();
                             break;
                           case 'width':
                             canvasWidth = this.getWidth();
                             canvasHeight = SVGViewer(this.topSprite.parent).getHeight();
                             break;
                           default:
                             this.dbg("invalid <svg> clip mode: "+ clipMode);
                           case 'both':
                             canvasWidth = this.getWidth();
                             canvasHeight = this.getHeight();
                             break;
                        }
                    }
                    else {*/
                        canvasWidth = this.getWidth();
                        canvasHeight = this.getHeight();
                  //  }
                    Shape(topSprite.mask).graphics.drawRect(drawSprite.x, drawSprite.y,
                                                                  canvasWidth, canvasHeight);
                    Shape(topSprite.mask).graphics.endFill();
                    // Draw an invisible rect to receive mouse events.
                    drawSprite.graphics.drawRect(drawSprite.x, drawSprite.y,
                                                 canvasWidth, canvasHeight);
                    drawSprite.graphics.endFill();
                }
            }
        }

        /** 
         * Called to generate AS3 graphics commands from the SVG instructions
         **/
        protected function generateGraphicsCommands():void {
            this._graphicsCommands = new Array();    
        }

        /**
         * Perform transformations defined by the transform attribute 
         **/
        public function transformNode():void {
            topSprite.transform.matrix = new Matrix();
            this.loadAttribute('x');    
            this.loadAttribute('y');

            // Tspan x,y replaces the parent text x,y instead of
            // offsetting the parent like every other node.
            // However, if the x or y is not specified, then use the parent.
            if (this is SVGTspanNode) {
                if (this.getAttribute('x',null) != null) {
                    drawSprite.x = drawSprite.x - this.svgParent.getAttribute('x',0);
                }
                if (this.getAttribute('y',null) != null) {
                    drawSprite.y = drawSprite.y - this.svgParent.getAttribute('y',0);
                }
            }
            
            this.loadAttribute('rotate', 'rotation');

            // Apply transform attribute 
            var trans:String = this.getAttribute('transform');
            if (trans) {
                topSprite.transform.matrix = this.parseTransform(trans,
                                                            topSprite.transform.matrix.clone());
            }
            
            var animResult:Array = this.getAllAnimsTransform();
            var animMatrix:Matrix = animResult[0];
            var isAdditive:Boolean = animResult[1];
            if (animMatrix != null) {
                // See Issue 311: Tranforms must be applied in correct order
                // and must account for additive attribute.
                if (isAdditive) {
                  var newMatrix:Matrix = topSprite.transform.matrix.clone();
                  animMatrix.concat(newMatrix);
                }
                topSprite.transform.matrix = animMatrix;
            }

            // Apply animateMotion
            var motionPos:SVGCoordinate = this.getAllAnimsMotion();
            if (!motionPos.isZero()) {
                var motiontx:Matrix = topSprite.transform.matrix.clone();
                motiontx.translate(motionPos.x, motionPos.y);
                topSprite.transform.matrix = motiontx;
            }
        }

        public function parseTransform(trans:String, baseMatrix:Matrix = null):Matrix {
            if (!baseMatrix) {
                baseMatrix = new Matrix();
            }
            
            if (trans != null) {
                var transArray:Array = trans.match(/\S+\(.*?\)/sg);
                transArray.reverse();
                for each(var tran:String in transArray) {
                    var tranArray:Array = tran.split('(',2);
                    if (tranArray.length == 2)
                    {
                        var command:String = String(tranArray[0]);
                        var args:String = String(tranArray[1]);
                        args = args.replace(')','');
                        args = args.replace(/\s+/sg,","); //Replace spaces with a comma
                        args = args.replace(/,{2,}/sg,","); // Remove any extra commas
                        args = args.replace(/^,/, ''); //Remove leading comma
                        args = args.replace(/,$/, ''); //Remove trailing comma
                        var argsArray:Array = args.split(',');

                        var nodeMatrix:Matrix = new Matrix();
                        switch (command) {
                            case "matrix":
                                if (argsArray.length == 6) {
                                    nodeMatrix.a = argsArray[0];
                                    nodeMatrix.b = argsArray[1];
                                    nodeMatrix.c = argsArray[2];
                                    nodeMatrix.d = argsArray[3];
                                    nodeMatrix.tx = argsArray[4];
                                    nodeMatrix.ty = argsArray[5];
                                }
                                break;

                            case "translate":
                                if (argsArray.length == 1) {
                                    nodeMatrix.tx = argsArray[0]; 
                                }
                                else if (argsArray.length == 2) {
                                    nodeMatrix.tx = argsArray[0]; 
                                    nodeMatrix.ty = argsArray[1]; 
                                }
                                break;

                            case "scale":
                                if (argsArray.length == 1) {
                                    nodeMatrix.a = argsArray[0];
                                    nodeMatrix.d = argsArray[0];
                                }
                                else if (argsArray.length == 2) {
                                    nodeMatrix.a = argsArray[0];
                                    nodeMatrix.d = argsArray[1];
                                }
                                break;
                                
                            case "skewX":
                                nodeMatrix.c = Math.tan(argsArray[0] * Math.PI / 180.0);
                                break;
                                
                            case "skewY":
                                nodeMatrix.b = Math.tan(argsArray[0] * Math.PI / 180.0);
                                break;
                                
                            case "rotate":
                                if (argsArray.length == 3) {
                                    nodeMatrix.translate(-argsArray[1], -argsArray[2]);
                                    nodeMatrix.rotate(Number(argsArray[0])* Math.PI / 180.0);
                                    nodeMatrix.translate(argsArray[1], argsArray[2]); 
                                }
                                else {
                                    nodeMatrix.rotate(Number(argsArray[0])* Math.PI / 180.0);
                                }
                                break;
                                
                            default:
                                //this.dbg('Unknown Transformation: ' + command);
                        }
                        baseMatrix.concat(nodeMatrix);
                    }
                }
            }
            
            return baseMatrix;
        }

        protected function draw():void {
            for each (var command:Array in this._graphicsCommands) {
                switch(command[0]) {
                    case "PATH":
                        this.nodeBeginFill();
                        drawSprite.graphics.drawPath(command[1].commands, command[1].data, command[1].winding);
                        this.nodeEndFill();
                        break;
                    case "LINE":
                        this.nodeBeginFill();
                        drawSprite.graphics.moveTo(command[1], command[2]);
                        drawSprite.graphics.lineTo(command[3], command[4]);
                        this.nodeEndFill();                
                        break;
                    case "RECT":
                        this.nodeBeginFill();
                        if (command.length == 5) {
                            drawSprite.graphics.drawRect(command[1], command[2],command[3], command[4]);
                        }
                        else {
                            drawSprite.graphics.drawRoundRect(command[1], command[2],command[3], command[4], command[5], command[6]);
                        }
                        this.nodeEndFill();                
                        break;        
                    case "CIRCLE":
                        this.nodeBeginFill();
                        drawSprite.graphics.drawCircle(command[1], command[2], command[3]);
                        this.nodeEndFill();
                        break;
                    case "ELLIPSE":
                        this.nodeBeginFill();                        
                        drawSprite.graphics.drawEllipse(command[1], command[2],command[3], command[4]);
                        this.nodeEndFill();
                        break;
                }
            }
        }

        /** 
         * Called at the start of drawing an SVG element.
         * Sets fill and stroke styles
         **/
        protected function nodeBeginFill():void {
            //Fill
            var color_and_alpha:Array = [0, 0];
            var color_core:Number = 0;
            var color_alpha:Number = 0;
            var fill_alpha:Number = 0;

            var fill:String = this.getStyleOrAttr('fill');
            // draw even if visibility = "hidden".  May be required for
            // pointer-events. Animation of visibility attribute independent of
            // drawNode() relies on the correct drawing state
            var matches:Array = fill.match(/url\(#([^\)]+)\)/si);
            if (matches != null && matches.length > 0) {
                var fillName:String = matches[1];
                this.svgRoot.addReference(this, fillName);
                var fillNode:SVGNode = this.svgRoot.getNode(fillName);
                if (!fillNode) {
                     // this happens normally
                     //this.dbg("Gradient " + fillName + " not (yet?) available for " + this.xml.@id);
                }
                if (fillNode is SVGGradient) {
                    SVGGradient(fillNode).beginGradientFill(this);
                }
                else if (fillNode is SVGPatternNode) {
                    SVGPatternNode(fillNode).beginPatternFill(this);
                }
            }
            else {
                if (fill == 'currentColor') {
                    fill = this.getStyleOrAttr('color');
                }
                // Still may draw for fill 'none' in order to get mouse events.
                if (fill != 'none') {
                    color_and_alpha = SVGUnits.getColorAndAlpha(fill);
                    color_core = color_and_alpha[0];
                    color_alpha = color_and_alpha[1];
                    fill_alpha = SVGUnits.parseNum( this.getStyleOrAttr('fill-opacity') ) * color_alpha;
                }
                var pointerEvents:String = this.getStyleOrAttr('pointer-events', 'visiblePainted');
                // Begin fill if there is a fill set, or if we need an invisible fill to get mouse events
                if (   (fill != 'none' && getStyleOrAttr('visibility') != 'hidden') 
                    || (pointerEvents == 'all') ) {
                    drawSprite.graphics.beginFill(color_core, fill_alpha);
                }

            }
            nodeBeginStroke();
        }

        protected function nodeBeginStroke():void {
            var shapeRendering:String = this.getStyle('shape-rendering'); 
            
            //Stroke
            var line_color:Number;
            var line_alpha:Number;
            var line_width:Number;

            var stroke:String = this.getStyleOrAttr('stroke', 'black');
            if ( (stroke == 'none') || (stroke == '') || (this.getStyleOrAttr('visibility') == 'hidden') ) {
                line_alpha = 0;
                line_color = 0;
                line_width = 0;
            }
            else {
                if (stroke == 'currentColor') {
                    stroke = this.getStyleOrAttr('color');
                }
                line_color = SVGUnits.parseNum(SVGUnits.getColor(stroke));
                line_alpha = SVGUnits.parseNum(this.getStyleOrAttr('stroke-opacity'));
                line_width = SVGUnits.parseNum(this.getStyleOrAttr('stroke-width'));
            }

            var capsStyle:String = this.getStyleOrAttr('stroke-linecap');
            if (capsStyle == 'round'){
                capsStyle = CapsStyle.ROUND;
            }
            else if (capsStyle == 'square'){
                capsStyle = CapsStyle.SQUARE;
            }
            else {
                capsStyle = CapsStyle.NONE;
            }
            
            var jointStyle:String = this.getStyleOrAttr('stroke-linejoin');
            if (jointStyle == 'round'){
                jointStyle = JointStyle.ROUND;
            }
            else if (jointStyle == 'bevel'){
                jointStyle = JointStyle.BEVEL;
            }
            else {
              // Issue 437: "Slow rendering with mitered corners"
              // http://code.google.com/p/svgweb/issues/detail?id=437
              // The SVG default is to use mitered joins, but this is _extremely_ slow on
              // Flash for some edge cases; using the Flash default joint style
              // is much faster, by about two orders of magnitude for certain
              // SVG files.
              if (shapeRendering == 'optimizeSpeed' || shapeRendering == 'auto'){
                // The SVG standard says that 'auto' on the shape-rendering property should 
                // optimize correctness over speed. However, we go against the
                // standard for SVG Web on this point for two reasons:
                // * If a developer uses shape-rendering: optimizeSpeed for native
                // SVG renderers, such as Firefox, the visual quality is very
                // degraded -- there is no way to specify that only one renderer
                // should be optimized for speed.
                // * The effect on performance is _huge_ for the Flash SVG Web
                // renderer.
                jointStyle = JointStyle.ROUND;
              } else {
                jointStyle = JointStyle.MITER;
              }
            }
                        
            var miterLimit:String = this.getStyleOrAttr('stroke-miterlimit');
            if (miterLimit == null) {
                miterLimit = '4';
            }
            
            drawSprite.graphics.lineStyle(line_width, line_color, line_alpha, false, LineScaleMode.NORMAL,
                                          capsStyle, jointStyle, SVGUnits.parseNum(miterLimit));
            // draw even if visibility = "hidden".  May be required for
            // pointer-events. Animation of visibility attribute independent of
            // drawNode() relies on the correct drawing state
            if ( (stroke != 'none') && (stroke != '') ) {
                var strokeMatches:Array = stroke.match(/url\(#([^\)]+)\)/si);
                if (strokeMatches != null && strokeMatches.length > 0) {
                    var strokeName:String = strokeMatches[1];
                    this.svgRoot.addReference(this, strokeName);
                    var strokeNode:SVGNode = this.svgRoot.getNode(strokeName);
                    if (!strokeNode) {
                         // this happens normally
                         //this.dbg("stroke gradient " + strokeName + " not (yet?) available for " + this.xml.@id);
                    }
                    if (strokeNode is SVGGradient) {
                         SVGGradient(strokeNode).lineGradientStyle(this, line_alpha);
                    }
                }
            }
        }
        
        /** 
         * Called at the end of drawing an SVG element
         **/
        protected function nodeEndFill():void {
            drawSprite.graphics.endFill();
        }

        /**
         * Check value of x against _minX and _maxX, 
         * Update values when appropriate
         **/
        protected function setXMinMax(value:Number):void {          
            if (_firstX) {
                _firstX = false;
                this.xMax = value;
                this.xMin = value;
                return;
            }
            
            if (value < this.xMin) {
                this.xMin = value;
            }
            if (value > this.xMax) {
                this.xMax = value;
            }
        }
        
        /**
         * Check value of y against _minY and _maxY, 
         * Update values when appropriate
         **/
        protected function setYMinMax(value:Number):void {
            if (_firstY) {
                _firstY = false;
                this.yMax = value;
                this.yMin = value;
                return;
            }
            
            if (value < this.yMin) {
                this.yMin = value;
            }
            if (value > this.yMax) {
                this.yMax = value;
            }
        }

        public function applyViewBox():void {
            // Apply viewbox transform
            var viewBox:String = this.getAttribute('viewBox');
            var preserveAspectRatio:String = this.getAttribute('preserveAspectRatio');

            if ( (viewBox != null) || (preserveAspectRatio != null) ) {
                var newMatrix:Matrix = new Matrix();

                if (preserveAspectRatio == null) {
                    preserveAspectRatio = 'xMidYMid meet';
                }

                /**
                 * Canvas, the viewport
                 **/
                var canvasWidth:Number;
                var canvasHeight:Number;
           /*     if (topSprite.parent is SVGViewerWeb) {
                    canvasWidth = SVGViewerWeb(topSprite.parent).getWidth();
                    canvasHeight = SVGViewerWeb(topSprite.parent).getHeight();
                }
                else {*/
                    canvasWidth = this.getWidth();
                    canvasHeight = this.getHeight();
            //    }

                /**
                 * Viewbox
                 **/
                var viewX:Number;
                var viewY:Number;
                var viewWidth:Number;
                var viewHeight:Number;
                if (viewBox != null) {
                    viewBox = viewBox.replace(/,/sg," "); //Replace commas with spaces
                    var points:Array = viewBox.split(/\s+/); //Split by white space 
                    viewX = SVGUnits.parseNum(points[0]);
                    viewY = SVGUnits.parseNum(points[1]);
                    viewWidth = SVGUnits.parseNum(points[2]);
                    viewHeight = SVGUnits.parseNum(points[3]);
                }
                else {
                    viewX = 0;
                    viewY = 0;
                    viewWidth = canvasWidth;
                    viewHeight = canvasHeight;
                }

                var oldAspectRes:Number = viewWidth / viewHeight;
                var newAspectRes:Number = canvasWidth /  canvasHeight;
                var cropWidth:Number;
                var cropHeight:Number;

                var alignMode:String = preserveAspectRatio.substr(0,8);
                var meetOrSlice:String = 'meet';
                if (preserveAspectRatio.indexOf('slice') != -1) {
                    meetOrSlice = 'slice';
                }

                /**
                 * Handle Scaling
                 **/
                if (alignMode == 'none') {
                    // stretch to fit viewport width and height

                    cropWidth = canvasWidth;
                    cropHeight = canvasHeight;
                }
                else {
                    if (meetOrSlice == 'meet') {
                        // shrink to fit inside viewport

                        if (newAspectRes > oldAspectRes) {
                            cropWidth = canvasHeight * oldAspectRes;
                            cropHeight = canvasHeight;
                        }
                        else {
                            cropWidth = canvasWidth;
                            cropHeight = canvasWidth / oldAspectRes;
                        }
    
                    }
                    else {
                        // meetOrSlice == 'slice'
                        // Expand to cover viewport.

                        if (newAspectRes > oldAspectRes) {
                            cropWidth = canvasWidth;
                            cropHeight = canvasWidth / oldAspectRes;
                        }
                        else {
                            cropWidth = canvasHeight * oldAspectRes;
                            cropHeight = canvasHeight;
                        }
    
                    }
                }
                var scaleX:Number = cropWidth / viewWidth;
                var scaleY:Number = cropHeight / viewHeight;
                newMatrix.translate(-viewX, -viewY);
                newMatrix.scale(scaleX, scaleY);

                /**
                 * Handle Alignment
                 **/
                var borderX:Number;
                var borderY:Number;
                var translateX:Number;
                var translateY:Number;
                if (alignMode != 'none') {
                    translateX=0;
                    translateY=0;
                    var xAlignMode:String = alignMode.substr(0,4);
                    switch (xAlignMode) {
                        case 'xMin':
                            break;
                        case 'xMax':
                            translateX = canvasWidth - cropWidth;
                            break;
                        case 'xMid':
                        default:
                            borderX = canvasWidth - cropWidth;
                            translateX = borderX / 2.0;
                            break;
                    }
                    var yAlignMode:String = alignMode.substr(4,4);
                    switch (yAlignMode) {
                        case 'YMin':
                            break;
                        case 'YMax':
                            translateY = canvasHeight - cropHeight;
                            break;
                        case 'YMid':
                        default:
                            borderY = canvasHeight - cropHeight;
                            translateY = borderY / 2.0;
                            break;
                    }
                    newMatrix.translate(translateX, translateY);
                }
                
                // cache the matrix to efficiently aid any zooming and 
                // panning operations later
                this._lastVBMatrix = newMatrix.clone();
                
                // apply any zoom and pan values that might be in effect
                // if we are the SVG root tag
                if (this is SVGSVGNode && this.svgParent == null) {
                  newMatrix.translate(this.svgRoot.currentTranslate.x, 
                                      this.svgRoot.currentTranslate.y);
                  newMatrix.scale(this.svgRoot.currentScale, 
                                  this.svgRoot.currentScale);
                }
                
                viewBoxSprite.transform.matrix = newMatrix;
            }
        }

        protected function applyClipPathMask():void {
            var attr:String;
            var match:Array;
            var node:SVGNode;
            var matrix:Matrix;

            attr = this.getStyleOrAttr('mask');
            if (!attr) {
                attr = this.getStyleOrAttr('clip-path');
            }

            if (attr) {
               match = attr.match(/url\(\s*#(.*?)\s*\)/si);
               if (match.length == 2) {
                   attr = match[1];
                   node = this.svgRoot.getNode(attr);
                   if (svgClipPathMask == node) {
                       return;
                   }
                   this.removeMask();
                   if (node) {
                       svgClipPathMask = node;

                       var newMask:SVGNode = node.clone();
                       newMask.isMask = true;

                       addSVGChildMask(newMask);
                       clipSprite.mask = newMask.topSprite;

                       newMask.topSprite.visible = true;
                       clipSprite.cacheAsBitmap = true;
                       // We need to cacheAsBitmap for group and path nodes
                       // to fix a strange problem with a path on line 336
                       // of samples/svg-files/juanmontoya_lingerie.svg
                       // Without cacheAsBitmap, this path is not clipped by the
                       // group node mask on line 329.
                       // Issue 345: cacheAsBitmap should only be used when
                       // necessary due to its large memory consumption.
                       if (this is SVGPathNode || this is SVGGroupNode) {
                           newMask.topSprite.cacheAsBitmap = true;
                       }
                   }
               }
            }
            else {
                this.removeMask();
            }
        }

        protected function removeMask():void {
            if (clipSprite != topSprite && clipSprite.mask) {
                clipSprite.mask.parent.removeChild(clipSprite.mask);
                clipSprite.mask = null;
                svgClipPathMask = null;
            }
        }

        /**
         * Add any assigned filters to node
         **/
        protected function setupFilters():void {
            var filterName:String = this.getStyleOrAttr('filter');
            if ( (filterName != null) && (filterName != '') && (filterName != 'none') ) {
                var matches:Array = filterName.match(/url\(#([^\)]+)\)/si);
                if (matches.length > 0) {
                    filterName = matches[1];
                    var filterNode:SVGNode = this.svgRoot.getNode(filterName);
                    if (filterNode) {
                        drawSprite.filters = SVGFilterNode(filterNode).getFilters(this);
                    }
                    else {
                        //this.dbg("filter " + filterName + " not (yet?) available for " + this.xml.@id);
                        // xxx add reference
                    }
                }
            }
        }

        protected function attachEventListeners():void {
            var action:String;

            action = this.getAttribute('onclick', null, false);
            if (action) {
                this.svgRoot.addActionListener(MouseEvent.CLICK, drawSprite);
            }

            action = this.getAttribute('onmousedown', null, false);
            if (action) {
                this.svgRoot.addActionListener(MouseEvent.MOUSE_DOWN, drawSprite);
            }

            action = this.getAttribute('onmouseup', null, false);
            if (action) {
                this.svgRoot.addActionListener(MouseEvent.MOUSE_UP, drawSprite);
            }

            action = this.getAttribute('onmousemove', null, false);
            if (action) {
                this.svgRoot.addActionListener(MouseEvent.MOUSE_MOVE, drawSprite);
            }

            action = this.getAttribute('onmouseover', null, false);
            if (action) {
                this.svgRoot.addActionListener(MouseEvent.MOUSE_OVER, drawSprite);
            }

            action = this.getAttribute('onmouseout', null, false);
            if (action) {
                this.svgRoot.addActionListener(MouseEvent.MOUSE_OUT, drawSprite);
            }
        }
                

        /*
         * Node registration triggered by stage add / remove
         */


        // FIXME: Move to child add/remove because the node may
        // not be added to the stage.
        protected function onAddedToStage(event:Event):void {
            this.registerSelf();
            if (this.original) {
                this.original.registerClone(this);
            }
        }

        protected function onRemovedFromStage(event:Event):void {
            topSprite.removeEventListener(Event.ENTER_FRAME, drawNode);
            this.unregisterSelf();
            if (this.original) {
                this.original.unregisterClone(this);
            }
        }

        protected function registerSelf():void {
            if (this._isClone || (getMaskAncestor() != null)) {
                return;
            }
            
            this.svgRoot.registerGUID(this);
            
            var id:String = this.getAttribute('id');

            if (id == _id) {
                return;
            }

            if (_id) {
                this.svgRoot.unregisterNode(this);
            }

            if (id && id != "") {
                _id = id;
                this.svgRoot.registerNode(this);
            }
        }

        protected function unregisterSelf():void {
            if (this._isClone || (getMaskAncestor() != null)) {
                return;
            }

            this.svgRoot.unregisterGUID(this);
            
            if (this._id) {
                this.svgRoot.unregisterNode(this);
                _id = null;
            }
        }

        /*
         * Attribute Handling
         */

        /** 
         * Gets an XML attribute from this node
         *
         * @param name XML attribute to retrieve from SVG XML.
         * @param defaultValue Default value to return if this attribute is
         * not defined. Defaults to null.
         * @param inherit Whether to look up the inheritance chain if this
         * property is inherited. Defaults to true.
         * @param applyAnimations Boolean, optional, defaults to true. Controls
         * whether we apply any SMIL animations that might be in flight to the
         * attribute. If false, then we return the base actual set value on
         * this node without reference to any animation changes.
         * @param applyStyle Boolean, optional, defaults to false. Controls whether
         * we get and set values from this node's style values as well as its
         * attribute values. If false, then we don't check or set a given
         * attribute name against the style value.
         * 
         * @return Returns the XML attribute value, or the defaultValue.
         **/
        public function getAttribute(name:String, 
                                     defaultValue:* = null,
                                     inherit:Boolean = true,
                                     applyAnimations:Boolean = true,
                                     applyStyle:Boolean = false):* {
            var value:String = this._getAttribute(name, defaultValue,
                                                  inherit, applyAnimations,
                                                  applyStyle);
            
            if (value !== null && value != 'inherit') {
                return value;
            }
            
            if (value == "inherit") {
                value = null;
            }
            
            if (ATTRIBUTES_NOT_INHERITED.indexOf(name) != -1) {            
                if (defaultValue == null) {
                    if (name == 'opacity') {
                        return '1';
                    }
                    // default fall through
                }
                return defaultValue;        
            }
            
            if (inherit && (this.svgParent != null)) {
                return SVGNode(this.svgParent).getAttribute(name, defaultValue, true, 
                                                                 applyAnimations, applyStyle);
            }
            
            return defaultValue;       
        }
        
        /**
         *
         * This method retrieves the attribute from the current node only and is
         * used as a helper for getAttribute, which has css parent inheritance logic.
         *
         **/
        protected function _getAttribute(name:String, defaultValue:* = null,
                                         inherit:Boolean = true,
                                         applyAnimations:Boolean = true,
                                         applyStyle:Boolean = false):* {
            var value:String;
            
            // If we are rendering a mask, then use a simple black fill.
            if (this.getMaskAncestor() != null) {
                if (  (name == 'opacity')
                    || (name == 'fill-opacity')
                    || (name == 'stroke-width')
                    || (name == 'stroke-opacity') ) {
                    return '1';
                }

                if (name == 'fill') {
                    return 'black';
                }

                if (name == 'stroke') {
                    return 'none';
                }

                if (name == 'filter') {
                    return 'none';
                }
            }

            if (applyAnimations) {
                value = getAnimAttribute(name, defaultValue, inherit,
                                         applyStyle);
                if (value !== null) {
                    return value;
                }
            }
           
            if (name == "href") {
                //this._xml@href handled normally
                value = this._xml.@xlink::href;                             
                if (value !== null && (value != "")) {
                    return value;
                }
            }

            if (name == "base") {
                value = this._xml.@aaa::base;                             
                if (value !== null && (value != "")) {
                    return value;
                }
            }

            // If node is the top level of a clone,
            // check for an override value from the parent.
            if (this.original && (this.svgParent is SVGUseNode)) {
                // <use> node already implements x, y, and transform
                if (name != 'x' && name != 'y' && name != 'transform') {
                    value = this.svgParent._getAttribute(name, null, false, true, true);
                    if (value !== null) {
                        return value;
                    }
                }
            }
           
            if (applyStyle && _styles.hasOwnProperty(name)) {
                return (_styles[name]);
            }
           
            var xmlList:XMLList = this._xml.attribute(name);
            
            if (xmlList.length() > 0) {
                return xmlList[0].toString();
            }
 
            return null;
        }
        
        public function getStyleOrAttr(name:String, defaultValue:* = null,
                                       inherit:Boolean = true,
                                       applyAnimations:Boolean = true):* {
            return getAttribute(name, defaultValue, inherit, applyAnimations, true);
        }
        
        // process all animations
        public function getAnimAttribute(name:String, defaultValue:* = null,
                                         inherit:Boolean = true,
                                         useStyle:Boolean = false):String {
            var animation:SVGAnimateNode;

            // transform is handled by getAllAnimsTransforms
            if (name == "transform")
                return null;
 
            var foundAnimation:Boolean = false;
            for each(animation in animations) {
                if (animation.getAttributeName() == name) {
                    foundAnimation = true;
                    break;
                }
            }
            if (!foundAnimation)
                return null;
 
            var isAdditive:Boolean = true;
            // Start with base value
            var baseVal:String = getAttribute(name, defaultValue, inherit, false,
                                              useStyle);
            var isPath:Boolean = name=='d';
            var animVal:Number;
            if (baseVal) {
                animVal = SVGUnits.parseNum(baseVal);
            }
            else if (!isPath) {
                animVal= 0;
            }
             
            // Handle discrete string values
            var discreteStringVal:String;
            var isColor:Boolean = (baseVal != null) && !isPath && SVGUnits.isColor(baseVal);
            var animValString:String = null;
            // Add or replace with animations
            for each(animation in animations) {
                if (   animation.getAttributeName() == name
                    && animation.isEffective() ) {
                    animValString = animation.getAnimValue();
                    if (animValString == null) continue;  // null is an error, or !isEffective
                    isColor = !isPath && (isColor || SVGUnits.isColor(animValString));
                    if (animation.isAdditive()) {
                        if (isColor) {
                            animVal = SVGUnits.addColors(animVal, SVGUnits.parseNum(animValString));
                        } else if (!isPath) {
                            animVal = animVal + SVGUnits.parseNum(animValString);
                        }
                    }
                    else {
                        if (isPath || isNaN(animVal = SVGUnits.parseNum(animValString))) {
                           discreteStringVal = animValString;
                        }
                    }
                }
            }
            if (animValString == null) //no animations
                return baseVal;
            if (discreteStringVal) {
                return discreteStringVal;
            } else {
                if (isColor) {
                    return SVGUnits.colorString(animVal);
                } else {
                    return String(animVal);
                }
            }
        }

        /** 
         * Compute cumulative animation transform.
         **/
        public function getAllAnimsTransform():Array {
            var animTransform:Matrix= new Matrix();
            var isAdditive:Boolean = true;

            // Issues 254, 311 and 331 are relevant to transform ordering.
            // The additive attribute is processed in order of appearance.
            var animsToApply:Array = new Array();
            for each(var animation:SVGAnimateNode in animations) {
                if (animation is SVGAnimateTransformNode && animation.isEffective()) {
                    var transAnim:SVGAnimateTransformNode = SVGAnimateTransformNode(animation);
                    if (!transAnim.isAdditive()) {
                        isAdditive=false;
                        animsToApply = new Array();
                    }
                    animsToApply.push(transAnim);
                }
            }
            // Transform animations are applied in reverse order of appearance.
            var animReverse:Array=animsToApply.reverse();
            for each (transAnim in animReverse) {
                animTransform.concat(transAnim.getAnimTransform());
            }

            return [ animTransform, isAdditive ];
        }

        public function getAllAnimsMotion():SVGCoordinate {
            var pos:SVGCoordinate = new SVGCoordinate(0,0);
            var mAnim:SVGAnimateMotionNode;
            for each(var animation:SVGAnimateNode in animations) {
                if (animation is SVGAnimateMotionNode && animation.isEffective()) {
                    mAnim = SVGAnimateMotionNode(animation);
                    if (!mAnim.isAdditive()) {
                        pos.zero();
                    }
                    var animPos:SVGCoordinate = mAnim.getAnimMotionPos();
                    if (animPos != null) pos.add(animPos);
                }
            }
            return pos;
        }

        public function setAttribute(name:String, value:String, attrNamespace:String = null):void {
            if (name == "style") {
                this._xml.@style = value;
                this.parseStyle();
            }
            if (attrNamespace != null) {
                // namespaced attribute, such as xlink:href
                var ns:Namespace = new Namespace(attrNamespace);
                this.xml.@ns::[name] = value.toString();
            }
            else {
                this._xml.@[name] = value;
            }
            handleAttrChange(name, value, attrNamespace);
        }
            
        public function handleAttrChange(name:String, value:String, attrNamespace:String = null):void {
            switch (name) {
                case 'onclick':
                case 'onmousedown':
                case 'onmousemove':
                case 'onmouseout':
                case 'onmouseover':
                case 'onmouseup':
                case 'onmousedown':
                    this.attachEventListeners();
                    break;

                case 'transform':
                case 'viewBox':
                case 'x':
                case 'y':
                case 'rotate':
                    this.transformNode();
                    this.applyViewBox();
                    break;

                case 'pointer-events':
                    if (value  == 'none') {
                        topSprite.mouseEnabled = false;
                        topSprite.mouseChildren = false;
                    }
                    else {
                        topSprite.mouseEnabled = true;
                        topSprite.mouseChildren = true;
                    }
                    break;

                default:
                    this.invalidateDisplay();
                    if (    (name == 'display' || name == 'visibility')
                         || (name == 'style' && value != null &&
                              ( value.indexOf('visibility') != -1
                              || value.indexOf('display') != -1 ))
                         || (this is SVGGroupNode || this is SVGTextNode) ) {
                        this.invalidateChildren();
                    }
                    break;
            }
            this.updateClones();
            if (getClipPathAncestor() != null) {
                getClipPathAncestor().updateClones();
            }
            if (getPatternAncestor() != null) {
                this.svgRoot.invalidateReferers(getPatternAncestor().id);
            }
        }
        
        /** Sets a style attribute in the style="" string. Note that this
         *  leaves XML attributes alone. For examle, if you set 
         *  the fill style to 'red', the XML fill attribute will remain with
         *  its old value. 
         **/
        public function setStyle(name:String, value:String):void {
            //this.dbg('setStyle, name='+name+', value='+value);
            this._styles[name] = value;
            this.updateStyle();
            this.parseStyle();
            
            handleAttrChange(name, value, null);
        }
        
        /** Gets a style attribute from the style="" string. Note that this
         *  leaves XML attributes alone. For examle, if you set 
         *  the fill style to 'red', the XML fill attribute will remain with
         *  its old value. Note that style values do not reflect changes
         *  that might apply due to SMIL animations; use getAttribute to
         *  an attribute that might have come into existence as part of a 
         *  SMIL animation.
         *
         *  @param name The style name, such as fill or stroke-width. Dashed
         *  style names will automatically be converted into camel case.
         *  @param defaultValue The default value to return if none is present.
         *  Defaults to null.
         *  @param inherit Whether to look up the inheritance chain if this
         *  property is inherited. Defaults to true.
         *
         *  @return The style value, or null if it is not present.
         **/
        public function getStyle(name:String, defaultValue:* = null, 
                                 inherit:Boolean = true):* {
            var value:String = this._getStyle(name);
            if (value !== null) {
                return value;
            }
                     
            if (_styles.hasOwnProperty(name)) {
                value = _styles[name];
            }
            
            if (value == "inherit") {
                value = null;
            }
            
            if (value !== null) {
                return value;
            }
            
            if (inherit && this.svgParent) {
                return this.svgParent.getStyle(name, defaultValue, inherit);
            }
            
            return defaultValue;
        }
        
        /** This method retrieves the style from the current node only and is
         *  used as a helper for getStyle. 
         **/
        protected function _getStyle(name:String):String {
            var value:String;
            
            // If we are rendering a mask, then use a simple black fill.
            if (this.getMaskAncestor() != null) {
                if ( (name == 'opacity')
                    || (name == 'fill-opacity')
                    || (name == 'stroke-width')
                    || (name == 'stroke-opacity') ) {
                    return '1';
                }

                if (name == 'fill') {
                    return 'black';
                }

                if (name == 'stroke') {
                    return 'none';
                }

                if (name == 'filter') {
                    return null;
                }
            }
            
            if (this.original && (this.svgParent is SVGUseNode)) {
                //Node is the top level of a clone
                //Check for an override value from the parent
                value = this.svgParent.getStyle(name, null, false);
                if (value !== null) {
                    return value;
                }
            }

            if (_styles.hasOwnProperty(name)) {
                return (_styles[name]);
            }
 
            return null;
        }

        private function parseStyle():void {
            //Get styling from XML attribute 'style'
            _styles = new Object();
            
            var xmlList:XMLList = this._xml.attribute('style');
            if (xmlList.length() > 0) {
                var styleString:String = xmlList[0].toString();
                
                // only one style value given, with no trailing semicolon?
                if (this._xml.@style.length()  && styleString.indexOf(';') == -1) {
                    // update our internal string to be correct moving forward
                    this._xml.@style = styleString + ';';
                    styleString += ';';
                }
                
                var styles:Array = styleString.split(';');
                for each(var style:String in styles) {
                    var styleSet:Array = style.split(':');
                    if (styleSet.length == 2) {
                        var attrName:String = SVGUnits.trim(styleSet[0]);
                        var attrValue:String = SVGUnits.trim(styleSet[1]);                        
                        this._styles[attrName] = attrValue;
                    }
                }
            }
        }
 
       /**
         * Update style attribute from _styles
         * <node style="...StyleString...">
         * 
         **/ 
        private function updateStyle():void {
            var newStyleString:String = '';
            
            for (var key:String in this._styles) {
                newStyleString += key + ':' + this._styles[key] + ';';
            }
            
            this._xml.@style = newStyleString;
        }
        
        /**
         * Returns true if this node can have text children. Subclasses
         * should override this if they want to have text node children.
         */
        public function hasText():Boolean {
            return false;
        }
        
        /**
         * Returns any text content this node might have as a child.
         */
        public function getText():String {
            return this._xml.text().toString();
        }
        
        /**
         * Sets any text content this node might have as a child.
         */
        public function setText(newValue:String):void {
            // subclasses should implement this if they want to have text
            throw new Error("Unimplemented");
        }
        
        public function onRegisterFont(fontFamily:String):void {
        }

        /**
         * Force a redraw of a node
         **/
        public function invalidateDisplay():void {
            if (this._invalidDisplay == false && topSprite) {
                this._invalidDisplay = true;
                topSprite.addEventListener(Event.ENTER_FRAME, drawNode);
                if (this._invalidAttribute) {
                    // if _invalidAttribute is already set then reset to prevent
                    // repeat processing performed by drawNode.
                    this._invalidAttribute = INVALID_ATTR_NONE;
                }            
            }
        }

        public function invalidateChildren():void {
            var child:SVGNode;
            for (var i:uint = 0; i < viewBoxSprite.numChildren; i++) {
                var node:DisplayObject = viewBoxSprite.getChildAt(i);
                if (!(node is SVGSprite)) {
                  // Issue 391: 
                  // "Get Jessyink demo working on SVG Web"
                  // http://code.google.com/p/svgweb/issues/detail?id=391
                  continue;
                }
                child = SVGSprite(node).svgNode;
                child.invalidateDisplay();
                child.invalidateChildren();
            }
        }

        // This is called when the element has not rendered yet.
        // TODO: When possible, compute the bounds without rendering.
        public function getBounds():Rectangle {
            return new Rectangle(0,0,0,0);
        }

        public function invalidateAttribute(attributeName:String):void {
            if (!this.topSprite || !this.topSprite.parent || this._invalidDisplay) return;
            var attr:uint = INVALID_ATTR_NONE;
            switch (attributeName) {
                case 'transform':
                case 'viewBox':
                case 'x':
                case 'y':
                case 'rotate':
                case 'motion':
                    attr = INVALID_ATTR_TRANSFORM;
                    break;
                case 'opacity' :
                    attr = INVALID_ATTR_OPACITY;
                    break;
                case 'visibility' :
                    attr = INVALID_ATTR_VISIBILITY;
                    break;
                case 'display' :
                    attr = INVALID_ATTR_DISPLAY;
                    break;
                default:
                    this.invalidateDisplay();
                    this.invalidateChildren();
                    break;
            }
            if (attr != INVALID_ATTR_NONE) {
                 if (this._invalidAttribute == INVALID_ATTR_NONE) {
                     topSprite.addEventListener(Event.ENTER_FRAME, invalidateAttributeHandler);
                 }
                 this._invalidAttribute |= attr;
            }
        }

        public function invalidateAttributeHandler(event:Event):void {
            // are we in the middle of a suspendRedraw operation?
            if (this.svgRoot.viewer && this.svgRoot.viewer.isSuspended) {
                return;
            }
            this.topSprite.removeEventListener(Event.ENTER_FRAME, invalidateAttributeHandler);

            if (this._invalidAttribute != INVALID_ATTR_NONE) {
                if (this._invalidAttribute & INVALID_ATTR_DISPLAY) {
                    if (this.getStyleOrAttr('display') == 'none') {
                        this.topSprite.visible = false;
                    }
                    else {
                        this.topSprite.visible = true;
                    }
                }
                if (this._invalidAttribute & INVALID_ATTR_OPACITY) {
                    if (this.drawSprite)
                      this.drawSprite.alpha = SVGUnits.parseNum(this.getStyleOrAttr('opacity'));
                }
                if (this._invalidAttribute & INVALID_ATTR_VISIBILITY) {
                     if (this.getStyleOrAttr('visibility') == 'hidden') {
                        this.setVisibility('hidden');
                    } else {
                        this.setVisibility('visible');
                    }
                }
                if (this._invalidAttribute & INVALID_ATTR_TRANSFORM) {
                    if (this is SVGSVGNode) {
                        this.loadAttribute('x');
                        this.loadAttribute('y');
                        this.applyDefaultMask();
                    }
                    this.transformNode();
                    this.applyViewBox();
                }
                this._invalidAttribute = INVALID_ATTR_NONE;
            }
        }

        /*
         * Clone Handlers
         */

        public function clone():SVGNode {
            var nodeClass:Class = getDefinitionByName(getQualifiedClassName(this)) as Class;
            var newXML:XML = this._xml.copy();

            var node:SVGNode = new nodeClass(this.svgRoot, newXML, this) as SVGNode;

            return node;
        }

        public function registerClone(clone:SVGNode):void {
            if (this._clones.indexOf(clone) == -1) {
               this._clones.push(clone);
            }
        }

        public function unregisterClone(clone:SVGNode):void {
            var index:int = this._clones.indexOf(clone);
            if (index > -1) {
                this._clones = this._clones.splice(index, 1);
            }
        }

        protected function updateClones():void {
            for (var i:uint = 0; i < this._clones.length; i++) {
               SVGNode(this._clones[i]).xml = this._xml.copy();
            }
        }

        public function get isClone():Boolean {
            return this._isClone;
        }
        
        /*
         * Animations
         */

        public function addAnimation(animation:SVGAnimateNode):void {
            if (animations.indexOf(animation) == -1) {
                animations.push(animation);
            }
        }

        public function removeAnimation(animation:SVGAnimateNode):void {
            if (animations.indexOf(animation) != -1) {
                animations.splice(animations.indexOf(animation), 1);
            }
        }

        // Move animation to the end of the list so it takes precedence.
        public function activateAnimation(animation:SVGAnimateNode):void {
            if (animations.indexOf(animation) != -1) {
                animations.splice(animations.indexOf(animation), 1);
            }
            animations.push(animation);
        }

        /*
         * Misc Functions
         */

        public function getWidth():Number {
            var parentWidth:Number=0;
            if (topSprite.parent is SVGViewer) {
                parentWidth = 0;
            }
            if (this.svgParent != null) {
                parentWidth = this.svgParent.getWidth();
            }
            if (this.getAttribute('width') != null) {
                return SVGUnits.parseNumPct(this.getAttribute('width'), parentWidth);
            }

            // defaults to 100%
            return parentWidth;
        }

        public function getHeight():Number {
            var parentHeight:Number=0;
            if (topSprite.parent is SVGViewer) {
                parentHeight = 0;
            }
            if (this.svgParent is SVGNode) {
                parentHeight=this.svgParent.getHeight();
            }
            if (this.getAttribute('height') != null) {
                return SVGUnits.parseNumPct(this.getAttribute('height'), parentHeight);
            }

            // defaults to 100%
            return parentHeight;
        }

        /** Appends an SVGNode both to our display list as well as to our
          * XML.
          **/
        public function appendSVGChild(child:SVGNode):SVGNode {
            this._xml.appendChild(child._xml);
            this.addSVGChildAt(child, svgChildren.length);
            this.invalidateDisplay();

            return child;
        }
        
        public function removeSVGChild(node:SVGNode):SVGNode {
            // Remove from svg list.
            var i:uint;
            for (i = 0; i < this.svgChildren.length; i++) {
                if (this.svgChildren[i] == node) {
                    this.svgChildren.splice(i, 1);
                    break;
                }
            }
            
            node.svgParent = null;
            
            // unregister the element
            this.svgRoot.unregisterNode(node);
            
            // if we are dealing with a fake text node, change our
            // text node contents
            if (node is SVGDOMTextNode && this.hasText()) {
                this.setText(null);
            }
            
            // remove from our XML children
            for (i = 0; i < this._xml.children().length(); i++) {
                if (this._xml.children()[i].@__guid == node._xml.@__guid) {
                    delete this._xml.children()[i];
                    break;
                }
            }
            
            // Remove from flash list.
            if ( node.topSprite ) {
                var child:DisplayObject;
                for (i = 0; i < viewBoxSprite.numChildren; i++) {
                    child = viewBoxSprite.getChildAt(i);
                    if (child == node.topSprite) {
                        viewBoxSprite.removeChild(child);
                    }
                }
                this.invalidateDisplay();
            }

            node.onRemoved();
            
            return node;
        }
        
        /**
         * Adds newChild before refChild. Position is the position of refChild
         * to add newChild before.
         */
        public function insertSVGBefore(position:int, newChild:SVGNode, refChild:SVGNode):void {
            //this.dbg('insertSVGBefore, position='+position+', newChild='+newChild+', refChild='+refChild);
            // update our XML
            this._xml.insertChildBefore(refChild.xml, newChild.xml);
    
            newChild.svgParent = this;
            this.svgChildren.splice(position, 0, newChild);

            if (newChild.topSprite) {
                // Adjust display list position for missing
                // DOM text nodes.
                var displayPosition:int = position;
                var i:uint;
                for (i = 0; i < position; i++) {
                    if (this.svgChildren[i] is SVGDOMTextNode) {
                       displayPosition--;
                    }
                }
                viewBoxSprite.addChildAt(newChild.topSprite, displayPosition);
                this.invalidateDisplay();
            }
            newChild.onAdded();
        }
        
        public function addSVGChildAt(child:SVGNode, index:int):SVGNode {
            // update XML
            if (child is SVGDOMTextNode) {
                if (this.hasText()) {
                    this.setText(child.xml.text());
                }
            } else {
                if (index == (this._xml.children().length() - 1)) {
                    this._xml.appendChild(child.xml);
                } else {
                    var insertBefore:XML = this._xml.children()[index];
                    this._xml.insertChildBefore(insertBefore, child.xml);
                }
            }

            child.svgParent = this;
            this.svgChildren.splice(index, 0, child);

            // update our Flash display list
            if (child.topSprite) {
                // Adjust display list position for missing
                // DOM text nodes.
                var displayIndex:uint = index;
                var i:uint;
                for (i = 0; i < index; i++) {
                    if (this.svgChildren[i] is SVGDOMTextNode) {
                       displayIndex--;
                    }
                }
                viewBoxSprite.addChildAt(child.topSprite, displayIndex);
            }
            child.onAdded();
            return child;
        }
        
        /**
         * Called when a node is added to its parent.
         */
        protected function onAdded():void {
            
        }

        /**
         * Called when a node is removed from its parent.
         */
        protected function onRemoved():void {
            
        }

        /**
         * Remove all child nodes
         **/        
        protected function clearSVGChildren():void {
            this.svgChildren = new Array();
            while (viewBoxSprite && viewBoxSprite.numChildren) {
                viewBoxSprite.removeChildAt(0);
            }
        }

        
        public function getMaskAncestor():SVGNode {
            var node:SVGNode = this;
            if ( node && node.isMask)
                return node;
            while (node && !(node is SVGSVGNode)) {
                node=node.svgParent;
                if (node && node.isMask)
                    return node;
            }
            return null;
        }

        public function getPatternAncestor():SVGPatternNode {
            var node:SVGNode = this;
            while (node && !(node is SVGSVGNode)) {
                node=node.svgParent;
                if (node is SVGPatternNode)
                    return SVGPatternNode(node);
            }
            return null;
        }

        public function getClipPathAncestor():SVGClipPathNode {
            var node:SVGNode = this;
            while (node && !(node is SVGSVGNode)) {
                node=node.svgParent;
                if (node is SVGClipPathNode)
                    return SVGClipPathNode(node);
            }
            return null;
        }
        
        public function addSVGChild(child:SVGNode):void {
            child.svgParent = this;
            this.svgChildren.push(child);
            if (child.topSprite) {
                this.viewBoxSprite.addChild(child.topSprite);
                child.svgRoot.renderPending();
            }
            child.onAdded();
        }

        public function addSVGChildMask(child:SVGNode):void {
            child.svgParent = this;
            topSprite.addChild(child.topSprite);
            child.svgRoot.renderPending();
        }
        
        /**
         * Getters / Setters
        **/
        public function set xml(xml:XML):void {
            _xml = xml;

            if (this.viewBoxSprite) {
                this.clearSVGChildren();
            }

            this._parsedChildren = false;
            this.parseStyle();

            if (!this.viewBoxSprite) {
                this.createSVGSprites();
            }

            this.invalidateDisplay();
            this.updateClones();
        }
        
        public function get xml():XML {
            return this._xml;
        }

        public function get id():String {
            var id:String = this._xml.@id;
            return id;
        }
        
        public function get guid():String {
            return this._xml.@__guid;
        }


        public function nsQualify(name:String, nameNS:Namespace):String {
            var n:int;
            var scopeNS:Namespace;
            for (n = 0; n < this.svgRoot._xml.inScopeNamespaces().length; n++) {
                scopeNS = this.svgRoot._xml.inScopeNamespaces()[n];
                if (scopeNS.prefix == "" && scopeNS.uri == nameNS.uri) {
                    return name;
                }
            }
            for (n = 0; n < this.svgRoot._xml.inScopeNamespaces().length; n++) {
                scopeNS = this.svgRoot._xml.inScopeNamespaces()[n];
                if (scopeNS.uri == nameNS.uri) {
                    return (scopeNS.prefix + ":" + name);
                }
            }
            return name;
        }

        public function getAttrs():String {
            var attrsString:String ="";
            var attrsNamesList:XMLList = xml.@*;
            for (var i:int = 0; i < attrsNamesList.length(); i++) {
                attrsString=attrsString.concat(' ', nsQualify(attrsNamesList[i].localName(),Namespace(attrsNamesList[i].namespace())), '=',
                                               '"',this._xml.@[attrsNamesList[i].name()],'"');
            }
            return attrsString;
        }

        public function getNameSpaces():String {
            var namespString:String ="";
            for (var i:int = 0; i < this._xml.inScopeNamespaces().length; i++) {
                var namesp:Namespace = this._xml.inScopeNamespaces()[i];
                if (namesp.prefix == "") {
                    namespString=namespString.concat(' xmlns', '=', '"',namesp.uri,'"');
                }
                else {
                    namespString=namespString.concat(' xmlns:', namesp.prefix, '=', '"',namesp.uri,'"');
                }
            }
            return namespString;
        }

        public function getXMLTree(indent:uint, includeOuterTag:Boolean):String {
            var i:uint;
            var xmlString:String="";
            var myTag:String="";

            // Cloned glyphs are artificial. Skip them.
            if (this is SVGGlyphNode && this.original) {
                return "";
            }

            myTag = nsQualify(this._xml.localName(), this._xml.namespace());

            if (this.svgChildren.length > 0) {
                // Open Outer tag
                if (includeOuterTag && !(this is SVGDOMTextNode)) {
                    for (i = 0; i < indent; i++) {
                       xmlString=xmlString.concat(' ');
                    }
                    if (this.topSprite.parent is SVGViewer) {
                        xmlString = xmlString.concat('<', myTag, this.getNameSpaces(), this.getAttrs(), '>\n');
                    }
                    else {
                        xmlString = xmlString.concat('<', myTag, this.getAttrs(), '>\n');
                    }
                }
                // Children
                for (i = 0; i < this.svgChildren.length; i++) {
                    xmlString = xmlString.concat(this.svgChildren[i].getXMLTree(indent+
                         (includeOuterTag ? 2 : 0), true));
                }
                // Close Outer Tag
                if (includeOuterTag && !(this is SVGDOMTextNode)) {
                    for (i = 0; i < indent; i++) {
                       xmlString=xmlString.concat(' ');
                    }
                    xmlString = xmlString.concat('</', myTag, '>\n');
                }
            }
            else {
                if (this is SVGDOMTextNode) {
                    if (SVGDOMTextNode(this).nodeValue) {
                        xmlString = xmlString.concat(SVGDOMTextNode(this).nodeValue);
                    }
                }
                else if (this is SVGScriptNode) {
                    var content:String;
                    if (this._xml.children().length() > 0) {
                        content = this._xml.children()[0].text().toString();
                        xmlString = xmlString.concat('<', myTag, this.getAttrs(), '><![CDATA[\n', content, ']]></', myTag, '>\n');
                    }
                    else {
                        xmlString = xmlString.concat('<', myTag, this.getAttrs(), '/>\n');
                    }
                }
                else {
                    if (includeOuterTag) {
                        for (i = 0; i < indent; i++) {
                           xmlString=xmlString.concat(' ');
                        }
                        xmlString = xmlString.concat('<', myTag, this.getAttrs(), '/>\n');
                    }
                }
            }
            return xmlString;
        }


        public function get invalidDisplay():Boolean {
            return this._invalidDisplay;
        }

/*
        public function dbg(debugString:String):void {
            this.svgRoot.debug(debugString);
        }
        
        public function err(errorString:String):void {
            this.svgRoot.error(errorString);
        }
        
        /** Functions for profiling. */
     /*   public function start(subject:String, subjectStarted:String = null):void {
            this.svgRoot.start(subject, subjectStarted);
        }*/
        
        /** Functions for profiling. */
      /*  public function end(subject:String, subjectStarted:String = null):void {
            this.svgRoot.end(subject, subjectStarted);
        }*/
        
        /** Functions for profiling. */
     /*   public function increment(subject:String, amount:int):void {
            this.svgRoot.increment(subject, amount);
        }*/

/* For Performance Testing
        public function countTree():Array {

            var nodeCount:Number = 1;
            var spriteCount:Number = 0;
            var domTextNodeCount:Number = 0;
            if (this is SVGDOMTextNode) {
                domTextNodeCount++;
            }
            else {
                spriteCount = 1;
                if (clipSprite != topSprite) {
                    spriteCount++;
                }
                if (drawSprite != clipSprite) {
                    spriteCount++;
                }
                if (viewBoxSprite != drawSprite) {
                    spriteCount++;
                }
            }

            var child:SVGNode;
            for (var i:uint = 0; i < this.svgChildren.length; i++) {
                child = this.svgChildren[i];
                var counts:Array = child.countTree();
                nodeCount += counts[0];
                spriteCount += counts[1];
                domTextNodeCount += counts[2];
            }

            return [ nodeCount, spriteCount, domTextNodeCount ];
        }
*/

    }
}
