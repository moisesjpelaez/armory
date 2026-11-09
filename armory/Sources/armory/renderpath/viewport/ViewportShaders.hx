package armory.renderpath.viewport;

/** Shader names shared by the Viewport renderers and their compositor. **/
class ViewportShaders {

	/** The handle path.loadShader() and drawShader() take for a shader whose file, shader data and context are all named `name`. **/
	public static inline function handle(name: String): String {
		return name + "/" + name + "/" + name;
	}
}
