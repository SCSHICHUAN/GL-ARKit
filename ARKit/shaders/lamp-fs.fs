/* 
  light.fragment.strings
  ARKit

  Created by Stan on 2024/8/12.
  
*/
#version 300 es
precision highp float;
precision highp int;
out vec4 FragColor;
uniform vec3 lampColor;

void main()
{
    FragColor = vec4(lampColor, 1.0); // set all 4 vector values to 1.0
}
