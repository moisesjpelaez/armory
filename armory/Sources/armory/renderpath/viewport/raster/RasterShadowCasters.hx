package armory.renderpath.viewport.raster;

import iron.Scene;
import iron.object.MeshObject;

/**
	Draws the meshes that cast a shadow into a shadow view's tile, skipping those
	that cannot reach the view (inView()). RasterShadows.render() calls draw() for
	every view, with the tile's viewport already set.
**/
class RasterShadowCasters {

	static var NO_BIND_PARAMS: Array<String> = [];

	/** Draws the shadow casters seen by `view` into its tile. **/
	public static function draw(g: kha.graphics4.Graphics, view: Int) {
		var o = RasterShadowViews.offset(view);
		// The lighting pass reads the atlas's depth as the view's linear depth. An
		// orthographic clip matrix gives that directly. Perspective views write it per pixel.
		var context = RasterShadowViews.isPerspective(o) ? RasterShadows.PERSPECTIVE_CONTEXT : RasterShadows.CONTEXT;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible || !mesh.visibleShadow) continue;
			if (!inView(mesh, o)) continue;
			// MeshObject.render() culls against the camera and skips objects hidden from
			// the camera. Neither applies to a shadow view: in Eevee, objects hidden from
			// the camera still cast shadows. So both are turned off for this draw.
			var culling = mesh.frustumCulling;
			var cameraVisible = mesh.visibleMesh;
			mesh.frustumCulling = false;
			mesh.visibleMesh = true;
			mesh.render(g, context, NO_BIND_PARAMS);
			mesh.frustumCulling = culling;
			mesh.visibleMesh = cameraVisible;
		}
	}

	/**
		Whether the mesh's bounding box may reach into the tile and depth range of the
		view whose floats start at `o` (RasterShadowViews.offset()).
	**/
	public static function inView(mesh: MeshObject, o: Int): Bool {
		var t = mesh.transform;
		var x = t.worldx(), y = t.worldy(), z = t.worldz();
		var v = RasterShadowViews.data;
		if (RasterShadowViews.isPerspective(o)) {
			// Perspective: in front of the view's plane through the light, and within its range
			var w = o + RasterShadowViews.ROW_W;
			var fx = v[w], fy = v[w + 1], fz = v[w + 2];
			var along = fx * x + fy * y + fz * z + v[w + 3];
			var r = halfExtent(mesh, fx, fy, fz) + t.radius * 0.5;
			return along + r > 0 && along - r < v[o + RasterShadowViews.NEAR] + v[o + RasterShadowViews.DEPTH_RANGE];
		}
		for (k in 0...2) {
			var i = o + (k == 0 ? RasterShadowViews.ROW_U : RasterShadowViews.ROW_V);
			var scale = Math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]);
			var c = v[i] * x + v[i + 1] * y + v[i + 2] * z + v[i + 3];
			var r = halfExtent(mesh, v[i] / scale, v[i + 1] / scale, v[i + 2] / scale) * scale;
			if (c + r < 0 || c - r > 1) return false;
		}
		var i = o + RasterShadowViews.ROW_DEPTH;
		var scale = Math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]);
		var depth = v[i] * x + v[i + 1] * y + v[i + 2] * z + v[i + 3];
		return depth - halfExtent(mesh, v[i] / scale, v[i + 1] / scale, v[i + 2] / scale) * scale <= 1;
	}

	/**
		Half the extent of the mesh's box along the unit direction (nx, ny, nz).
		This is tighter than the bounding sphere for long or flat objects. The sphere
		would stretch the depth ranges, giving coarser cascades and a wider blocker search.
	**/
	public static function halfExtent(mesh: MeshObject, nx: Float, ny: Float, nz: Float): Float {
		var m = mesh.transform.world;
		var dim = mesh.transform.dim;
		return axisExtent(m._00, m._01, m._02, dim.x, nx, ny, nz)
			+ axisExtent(m._10, m._11, m._12, dim.y, nx, ny, nz)
			+ axisExtent(m._20, m._21, m._22, dim.z, nx, ny, nz);
	}

	/** Half of one box axis (direction a, `size` in local units) projected on n. **/
	static inline function axisExtent(ax: Float, ay: Float, az: Float, size: Float, nx: Float, ny: Float, nz: Float): Float {
		var length = Math.sqrt(ax * ax + ay * ay + az * az);
		return length > 0 ? 0.5 * size * Math.abs(ax * nx + ay * ny + az * nz) / length : 0.0;
	}
}
